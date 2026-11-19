/* ==========================================================================
   canvas-iso.client.js — zero-dependency isometric renderer, Crossy-Road style.

   Draws a topology (from topologies.js) as a toy board: chunky beveled blocks
   for each node with soft long shadows, and packets that *hop* along the
   connections like traffic crossing the board. Pure 2D canvas, no libraries,
   SSR-safe (imported client-side only). The board floats free — no terrain,
   no frame. Returns a controller with .setTopology() and .destroy().
   ========================================================================== */

import { KIND_STYLE, NODE_ICON, NODE_VENDORS, indexNodes } from "./topologies.js";

// Isometric basis. Logical (x, y, z) → screen (sx, sy). The tile size is
// computed at runtime to fit the canvas (see fit()); everything else is a
// ratio of it, so the board scales as one piece.
const ISO = 0.6; // vertical foreshortening (0.5 = 2:1 iso, →1 = top-down)
const BLOCK = 0.46; // block half-footprint as a fraction of tile (→ more gap)
const HEIGHT_R = 0.42; // block lift per z, as a fraction of tile
const CH_R = 0.42; // chunky block body height, as a fraction of tile
const FILL_X = 0.9; // share of canvas width the board fills
const FILL_Y = 0.86; // share of canvas height the board fills
const MAX_TILE = 170; // cap so it doesn't get cartoonish on huge screens

// shared lighting model (shade factors) for every iso box face
const FACE = { left: -0.34, right: -0.08, top: 0.22, bevel: 0.42 };

// cloud silhouette: heavily-overlapping puffs [dx, dy, r] as fractions of a
// tile. They must overlap generously so the union has no concave notches
// (a gap would show the dark background through as a wedge).
const CLOUD_PUFFS = [
  [0.0, -0.05, 0.46], // center dome
  [-0.32, 0.06, 0.3], // left
  [0.3, 0.04, 0.34], // right
  [0.2, 0.18, 0.28], // right-bottom (closes the right notch)
  [-0.05, -0.22, 0.3], // top bump
  [-0.05, 0.17, 0.32], // bottom-center
  [-0.22, 0.15, 0.27], // bottom-left
];

const hexToRgb = (hex) => {
  const h = hex.replace("#", "");
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
};
const shade = (rgb, t) =>
  rgb.map((c) => Math.round(t >= 0 ? c + (255 - c) * t : c * (1 + t)));
const css = (rgb, a = 1) => `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;

export function createIsoScene(canvas, opts = {}) {
  const onHover = opts.onHover || (() => {});
  const ctx = canvas.getContext("2d");
  let dpr = 1;
  let cx = 0;
  let cy = 0;
  let topo = null;
  let nodeIndex = {};
  let raf = null;
  let running = false;
  let t0 = null;
  let hover = null;
  let lastReported = undefined; // last hover id sent to onHover
  let pointer = { x: -1, y: -1 };
  let shadowLayer = null; // baked offscreen shadow canvas
  let sortedNodes = []; // back-to-front draw order, cached per topology
  let zoneRects = []; // [{id,label,tint,minX,maxX,minY,maxY}] hosting boundaries
  let nodeZone = {}; // nodeId → its zone rect (for drag clamping)
  let dragId = null; // node currently being dragged
  let lastPtr = null; // last pointer pos during a drag (css px)

  // inbox2 brand baked once, stamped onto the cloud floor in perspective
  let brandImg = null;
  let brandSprite = null;
  let brandReady = false;

  // lazy <img> cache for node brand logos (shape "logo")
  const logoCache = {};
  function logoFor(src) {
    let img = logoCache[src];
    if (!img) {
      img = new Image();
      img.src = src;
      logoCache[src] = img;
    }
    return img;
  }

  // runtime sizing — set by fit()
  let TILE = 82;
  let VY = TILE * ISO;
  let CH = TILE * CH_R;
  let HEIGHT = TILE * HEIGHT_R;

  // cached packet-glow sprite (avoids a radial gradient per packet per frame)
  const GLOW = (() => {
    const s = document.createElement("canvas");
    const S = 64;
    s.width = s.height = S;
    const g = s.getContext("2d");
    const grad = g.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
    grad.addColorStop(0, "rgba(212,232,255,1)");
    grad.addColorStop(0.45, "rgba(150,190,255,0.5)");
    grad.addColorStop(1, "rgba(120,170,255,0)");
    g.fillStyle = grad;
    g.fillRect(0, 0, S, S);
    return s;
  })();

  // device-pixel projection (includes the fitted tile size)
  function project(x, y, z) {
    return { sx: (x - y) * TILE, sy: (x + y) * VY - z * HEIGHT };
  }
  // grid (x, y, z) → on-screen device-pixel point (origin offset + dpr scale)
  function gridToScreen(x, y, z = 0) {
    const p = project(x, y, z);
    return { x: cx + p.sx * dpr, y: cy + p.sy * dpr };
  }

  function resize() {
    const r = canvas.getBoundingClientRect();
    if (!r.width || !r.height) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    fit();
  }

  // Compute a tile size that makes the whole board fill the canvas, then
  // centre it. Measures the board in unit-tile space and scales to fit.
  function fit() {
    if (!topo) {
      cx = canvas.width / 2;
      cy = canvas.height / 2;
      return;
    }
    // measure in unit space (tile = 1)
    let uMinX = Infinity, uMaxX = -Infinity, uMinY = Infinity, uMaxY = -Infinity;
    const accU = (sx, sy) => {
      uMinX = Math.min(uMinX, sx); uMaxX = Math.max(uMaxX, sx);
      uMinY = Math.min(uMinY, sy); uMaxY = Math.max(uMaxY, sy);
    };
    for (const node of topo.nodes) {
      const ux = node.x - node.y;
      const uyTop = (node.x + node.y) * ISO - node.z * HEIGHT_R;
      const uyBot = (node.x + node.y) * ISO;
      accU(ux - BLOCK, uyTop - CH_R - 0.5); // block left + label headroom
      accU(ux + BLOCK, uyBot + BLOCK + 0.2); // block right + footprint
    }
    // include every zone boundary + its label headroom so nothing clips
    for (const z of zoneRects) {
      for (const [x, y] of [[z.minX, z.minY], [z.maxX, z.minY], [z.maxX, z.maxY], [z.minX, z.maxY]]) {
        accU(x - y, (x + y) * ISO);
      }
      // zone label sits just above the top corner
      accU(z.minX - z.minY, (z.minX + z.minY) * ISO - 0.5);
    }
    const boardW = uMaxX - uMinX || 1;
    const boardH = uMaxY - uMinY || 1;
    const tile = Math.min(
      (canvas.width * FILL_X) / boardW,
      (canvas.height * FILL_Y) / boardH,
      MAX_TILE * dpr,
    );
    // commit fitted sizes (already in device px, so no extra *dpr downstream
    // for projection — but block drawing still multiplies by dpr, so divide).
    TILE = tile / dpr;
    VY = TILE * ISO;
    CH = TILE * CH_R;
    HEIGHT = TILE * HEIGHT_R;

    // centre using the real projection
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    const acc = (sx, sy) => {
      minX = Math.min(minX, sx); maxX = Math.max(maxX, sx);
      minY = Math.min(minY, sy); maxY = Math.max(maxY, sy);
    };
    for (const node of topo.nodes) {
      const top = project(node.x, node.y, node.z);
      acc(top.sx - TILE * BLOCK, top.sy - CH - VY * BLOCK - 28);
      const g = project(node.x, node.y, 0);
      acc(g.sx + TILE * BLOCK, g.sy + VY * BLOCK);
    }
    const midX = (minX + maxX) / 2;
    const midY = (minY + maxY) / 2;
    cx = canvas.width / 2 - midX * dpr;
    cy = canvas.height / 2 - midY * dpr;

    bakeShadows(); // re-bake the static shadow layer for the new layout
  }

  function toScreen(node) {
    return gridToScreen(node.x, node.y, node.z);
  }
  function groundScreen(node) {
    return gridToScreen(node.x, node.y, 0);
  }

  /* ---- hosting-boundary zones on the floor ---------------------------
     Each zone is a labelled dashed boundary on the z=0 ground plane, an
     isometric rectangle aligned to the grid axes (so its edges run parallel
     to the block edges) with rounded corners and a faint tinted fill. The
     blocks float above it. Multiple zones can co-exist (e.g. on-prem +
     inbox2 Cloud). */
  function drawZones(g) {
    for (const z of zoneRects) drawZone(g, z);
  }

  function drawZone(g, z) {
    const rgb = hexToRgb(z.tint);
    const P = [
      [z.minX, z.minY], [z.maxX, z.minY], [z.maxX, z.maxY], [z.minX, z.maxY],
    ].map(([x, y]) => gridToScreen(x, y, 0));

    // rounded-corner path: straight iso edges, small arcs at the vertices
    const rFrac = 0.14;
    const lerp = (a, b, t) => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
    g.save();
    g.beginPath();
    for (let i = 0; i < 4; i++) {
      const prev = P[(i + 3) % 4];
      const cur = P[i];
      const next = P[(i + 1) % 4];
      const a = lerp(cur, prev, rFrac);
      const b = lerp(cur, next, rFrac);
      if (i === 0) g.moveTo(a.x, a.y);
      else g.lineTo(a.x, a.y);
      g.quadraticCurveTo(cur.x, cur.y, b.x, b.y);
    }
    g.closePath();
    g.fillStyle = css(rgb, 0.06);
    g.fill();
    g.setLineDash([2 * dpr, 8 * dpr]);
    g.lineCap = "round";
    g.lineWidth = 1.5 * dpr;
    g.strokeStyle = css(shade(rgb, 0.35), 0.6);
    g.stroke();
    g.setLineDash([]);
    g.restore();

    // zone label — a small chip pinned to the top (back) corner
    if (z.label) {
      const corner = gridToScreen(z.minX, z.minY, 0); // top vertex of the diamond
      g.font = `${11 * dpr}px "JetBrains Mono", ui-monospace, monospace`;
      g.textAlign = "left";
      g.textBaseline = "middle";
      const tw = g.measureText(z.label.toUpperCase()).width;
      const padX = 8 * dpr;
      const h = 20 * dpr;
      const lx = corner.x + 6 * dpr;
      const ly = corner.y - 2 * dpr;
      g.fillStyle = css(shade(rgb, -0.55), 0.85);
      g.beginPath();
      g.roundRect(lx, ly - h / 2, tw + padX * 2, h, 5 * dpr);
      g.fill();
      g.strokeStyle = css(shade(rgb, 0.3), 0.7);
      g.lineWidth = 1 * dpr;
      g.stroke();
      g.fillStyle = css(shade(rgb, 0.75), 0.95);
      g.fillText(z.label.toUpperCase(), lx + padX, ly);
    }
  }

  /* ---- inbox2 brand on the cloud floor -------------------------------
     Baked once (grayscale mark + wordmark) into a sprite, then stamped onto
     the floor plane with an isometric transform so it reads in perspective.
     Sits in the top-right corner of the cloud plot. */
  function bakeBrand() {
    const w = 620, h = 180;
    if (!brandSprite) brandSprite = document.createElement("canvas");
    brandSprite.width = w;
    brandSprite.height = h;
    const g = brandSprite.getContext("2d");
    g.clearRect(0, 0, w, h);
    let x = 4;
    if (brandImg && brandImg.complete && brandImg.naturalWidth) {
      const mh = 150;
      const mw = (mh * brandImg.naturalWidth) / brandImg.naturalHeight;
      g.save();
      g.filter = "grayscale(1) brightness(1.7)";
      g.globalAlpha = 0.9;
      g.drawImage(brandImg, x, (h - mh) / 2, mw, mh);
      g.restore();
      x += mw + 26;
    }
    g.fillStyle = "rgba(205,211,219,1)";
    g.font = '700 122px Oxanium, "Chakra Petch", sans-serif';
    g.textBaseline = "middle";
    g.textAlign = "left";
    g.fillText("inbox2", x, h / 2 + 8);
    brandReady = true;
  }

  // The inbox2 wordmark only sits on inbox2-hosted infra (zone id "inbox2"),
  // never on "your cloud" / "on-prem" / "your device". Skipped when that zone
  // is too small to fit the wordmark (e.g. on-prem hosts only MX with us).
  function brandZone() {
    const z = zoneRects.find((r) => r.id === "inbox2");
    if (!z || z.maxX - z.minX < 2.6) return null;
    return z;
  }

  function drawFloorBrand(g) {
    const z = brandReady ? brandZone() : null;
    if (!z) return;
    const { maxX, minY } = z;
    const wGrid = 1.95;
    const hGrid = (wGrid * brandSprite.height) / brandSprite.width;
    // anchor near the top-right edge (high x, low y), nudged inside
    const gx = maxX - 0.4 - wGrid;
    const gy = minY + 0.5;
    g.save();
    // isometric floor transform: local (gx,gy) grid → screen, z = 0
    g.setTransform(
      TILE * dpr, VY * dpr, -TILE * dpr, VY * dpr, cx, cy,
    );
    g.globalAlpha = 0.5;
    g.imageSmoothingQuality = "high";
    g.drawImage(brandSprite, gx, gy, wGrid, hGrid);
    g.restore();
  }

  /* ---- soft drop shadows (baked once into an offscreen layer) ---------
     The blur filter is expensive, so we render the whole shadow layer once
     per layout into an offscreen canvas and just stamp it each frame. Node
     positions are static, so this never needs to run in the hot loop. */
  function bakeShadows() {
    if (!shadowLayer) shadowLayer = document.createElement("canvas");
    shadowLayer.width = canvas.width;
    shadowLayer.height = canvas.height;
    const g = shadowLayer.getContext("2d");
    g.clearRect(0, 0, shadowLayer.width, shadowLayer.height);
    g.filter = `blur(${5 * dpr}px)`;
    g.fillStyle = css([0, 0, 0], 0.34);
    for (const node of topo.nodes) {
      const base = groundScreen(node);
      const ox = 14 * dpr + node.z * 6 * dpr; // taller blocks throw farther
      const oy = 11 * dpr + node.z * 5 * dpr;
      const w = TILE * BLOCK * dpr;
      const h = VY * BLOCK * dpr;
      g.beginPath();
      g.moveTo(base.x + ox, base.y - h + oy);
      g.lineTo(base.x + w + ox, base.y + oy);
      g.lineTo(base.x + ox, base.y + h + oy);
      g.lineTo(base.x - w + ox, base.y + oy);
      g.closePath();
      g.fill();
    }
  }

  /* ---- node dispatch: blocks vs cloud vs device ----------------------
     Returns the highest screen-Y of the drawn shape, so labels can sit
     just above whatever silhouette this node uses. */
  function drawNode(g, node) {
    const shape = node.shape || KIND_STYLE[node.kind].shape || "cube";
    if (shape === "cloud") return drawCloud(g, node);
    if (shape === "logo") return drawLogo(g, node);
    if (shape === "glyph") return drawGlyph(g, node);
    if (shape === "monitor" || shape === "phone" || shape === "device")
      return drawDevice(g, node, shape);
    return drawBlock(g, node);
  }

  /* ---- a floating brand logo (Gmail, Office 365 …) -------------------- */
  function drawLogo(g, node) {
    const c = toScreen(node);
    const dim = hover && hover !== node.id ? 0.5 : 1;
    const w = 1.05 * TILE * dpr;
    const img = logoFor(NODE_ICON[node.id]);
    if (!img.complete || !img.naturalWidth) return c.y - w * 0.5;
    const h = (w * img.naturalHeight) / img.naturalWidth;
    g.save();
    g.globalAlpha = dim;
    g.shadowColor = `rgba(190, 210, 255, ${hover === node.id ? 0.6 : 0.32})`;
    g.shadowBlur = 16 * dpr;
    g.imageSmoothingQuality = "high";
    g.drawImage(img, c.x - w / 2, c.y - h / 2, w, h);
    g.restore();
    return c.y - h / 2;
  }

  /* ---- a floating glyph badge (IMAP → "@") --------------------------- */
  function drawGlyph(g, node) {
    const c = toScreen(node);
    const dim = hover && hover !== node.id ? 0.5 : 1;
    const s = TILE * dpr;
    g.save();
    g.font = `700 ${1.25 * s}px Oxanium, "Chakra Petch", sans-serif`;
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.shadowColor = `rgba(150, 200, 255, ${hover === node.id ? 0.85 : 0.55})`;
    g.shadowBlur = 20 * dpr;
    g.fillStyle = css([214, 230, 255], dim);
    g.fillText(NODE_ICON[node.id] || "@", c.x, c.y);
    g.restore();
    return c.y - 0.85 * s;
  }

  /* ---- a single chunky block ------------------------------------------ */
  function drawBlock(g, node) {
    const style = KIND_STYLE[node.kind];
    const rgb = hexToRgb(style.hex);
    const top = toScreen(node);
    const w = TILE * BLOCK * dpr;
    const h = VY * BLOCK * dpr;
    const dim = hover && hover !== node.id ? 0.4 : 1;

    // pillar for lifted blocks
    if (node.z > 0) {
      const g0 = groundScreen(node);
      g.strokeStyle = css(shade(rgb, -0.2), 0.3 * dim);
      g.lineWidth = 2 * dpr;
      g.setLineDash([5 * dpr, 5 * dpr]);
      g.beginPath();
      g.moveTo(top.x, top.y + h);
      g.lineTo(g0.x, g0.y);
      g.stroke();
      g.setLineDash([]);
    }

    // left face
    g.fillStyle = css(shade(rgb, FACE.left), dim);
    g.beginPath();
    g.moveTo(top.x - w, top.y);
    g.lineTo(top.x, top.y + h);
    g.lineTo(top.x, top.y + h + CH * dpr);
    g.lineTo(top.x - w, top.y + CH * dpr);
    g.closePath();
    g.fill();

    // right face (lighter — key light side)
    g.fillStyle = css(shade(rgb, FACE.right), dim);
    g.beginPath();
    g.moveTo(top.x + w, top.y);
    g.lineTo(top.x, top.y + h);
    g.lineTo(top.x, top.y + h + CH * dpr);
    g.lineTo(top.x + w, top.y + CH * dpr);
    g.closePath();
    g.fill();

    // top face
    g.fillStyle = css(shade(rgb, FACE.top), dim);
    g.beginPath();
    g.moveTo(top.x, top.y - h);
    g.lineTo(top.x + w, top.y);
    g.lineTo(top.x, top.y + h);
    g.lineTo(top.x - w, top.y);
    g.closePath();
    g.fill();

    // toy bevel: a smaller inset top face, brighter
    const bi = 0.62;
    g.fillStyle = css(shade(rgb, FACE.bevel), dim);
    g.beginPath();
    g.moveTo(top.x, top.y - h * bi);
    g.lineTo(top.x + w * bi, top.y);
    g.lineTo(top.x, top.y + h * bi);
    g.lineTo(top.x - w * bi, top.y);
    g.closePath();
    g.fill();

    // hover halo
    if (hover === node.id) {
      g.strokeStyle = css(hexToRgb(style.glow), 0.95);
      g.lineWidth = 2.5 * dpr;
      g.beginPath();
      g.moveTo(top.x, top.y - h - 5 * dpr);
      g.lineTo(top.x + w + 5 * dpr, top.y);
      g.lineTo(top.x, top.y + h + 5 * dpr);
      g.lineTo(top.x - w - 5 * dpr, top.y);
      g.closePath();
      g.stroke();
    }
    return top.y - h;
  }

  /* ---- a 3D cloud (the internet) -------------------------------------
     A rounded puff cluster filled as ONE silhouette (no internal outlines),
     shaded like a volume: light top, deep bottom, a bright upper-left
     highlight and a soft underside shadow, plus an outer glow. */
  function drawCloud(g, node) {
    const rgb = hexToRgb(KIND_STYLE[node.kind].hex);
    const c = toScreen(node);
    const dim = hover && hover !== node.id ? 0.5 : 1;
    const s = TILE * dpr;
    const path = new Path2D();
    for (const [lx, ly, r] of CLOUD_PUFFS) {
      path.arc(c.x + lx * s, c.y + ly * s, r * s, 0, Math.PI * 2);
    }

    g.save();
    // outer glow
    g.shadowColor = css(shade(rgb, 0.4), (hover === node.id ? 0.85 : 0.55) * dim);
    g.shadowBlur = 18 * dpr;
    // base volume gradient (top light → bottom deep)
    const grad = g.createLinearGradient(0, c.y - 0.55 * s, 0, c.y + 0.4 * s);
    grad.addColorStop(0, css(shade(rgb, 0.62), dim));
    grad.addColorStop(0.55, css(shade(rgb, 0.28), dim));
    grad.addColorStop(1, css(shade(rgb, -0.08), dim));
    g.fillStyle = grad;
    g.fill(path);
    g.shadowBlur = 0;

    // shading confined to the silhouette
    g.clip(path);
    // bright upper-left highlight (the light source)
    const hl = g.createRadialGradient(
      c.x - 0.14 * s, c.y - 0.28 * s, 0,
      c.x - 0.14 * s, c.y - 0.28 * s, 0.62 * s,
    );
    hl.addColorStop(0, css(shade(rgb, 0.92), 0.7 * dim));
    hl.addColorStop(1, css(shade(rgb, 0.92), 0));
    g.fillStyle = hl;
    g.fillRect(c.x - 0.7 * s, c.y - 0.7 * s, 1.4 * s, 1.4 * s);
    // deep underside shadow (gives the round bottom volume)
    const sh = g.createRadialGradient(
      c.x + 0.1 * s, c.y + 0.42 * s, 0,
      c.x + 0.1 * s, c.y + 0.42 * s, 0.6 * s,
    );
    sh.addColorStop(0, css(shade(rgb, -0.4), 0.55 * dim));
    sh.addColorStop(1, css(shade(rgb, -0.4), 0));
    g.fillStyle = sh;
    g.fillRect(c.x - 0.7 * s, c.y - 0.2 * s, 1.4 * s, 0.9 * s);
    g.restore();

    return c.y - 0.6 * s;
  }

  /* ---- generic iso box (used by device shapes) ------------------------
     base = bottom-centre screen point; gx, gy = grid half-extents; h = px
     height. Draws left/right/top faces, plus an optional glowing screen on
     the front-left face. */
  function isoBox(g, base, gx, gy, h, rgb, dim, screen) {
    const axx = gx * TILE * dpr, axy = gx * VY * dpr; // +x dir
    const ayx = -gy * TILE * dpr, ayy = gy * VY * dpr; // +y dir
    const T = { x: base.x, y: base.y - h };
    const corner = (i, j) => ({ x: T.x + i * axx + j * ayx, y: T.y + i * axy + j * ayy });
    const tBack = corner(-1, -1), tRight = corner(1, -1), tFront = corner(1, 1), tLeft = corner(-1, 1);
    const drop = (p) => ({ x: p.x, y: p.y + h });
    const quad = (pts, fill) => {
      g.fillStyle = fill;
      g.beginPath();
      g.moveTo(pts[0].x, pts[0].y);
      for (let k = 1; k < pts.length; k++) g.lineTo(pts[k].x, pts[k].y);
      g.closePath();
      g.fill();
    };
    quad([tLeft, tFront, drop(tFront), drop(tLeft)], css(shade(rgb, FACE.left), dim)); // left
    quad([tFront, tRight, drop(tRight), drop(tFront)], css(shade(rgb, FACE.right), dim)); // right
    quad([tBack, tRight, tFront, tLeft], css(shade(rgb, FACE.top), dim)); // top
    if (screen) {
      // glowing screen inset on the front-left face
      const p = [tLeft, tFront, drop(tFront), drop(tLeft)];
      const ctr = {
        x: (p[0].x + p[1].x + p[2].x + p[3].x) / 4,
        y: (p[0].y + p[1].y + p[2].y + p[3].y) / 4,
      };
      const inset = (q) => ({ x: q.x + (ctr.x - q.x) * 0.16, y: q.y + (ctr.y - q.y) * 0.16 });
      quad(p.map(inset), css(hexToRgb(screen), 0.92 * dim));
    }
    return T.y - axy - ayy; // highest point (top-back corner)
  }

  /* ---- endpoint client device (monitor / phone) ----------------------- */
  function drawDevice(g, node, shape) {
    const style = KIND_STYLE[node.kind];
    const rgb = hexToRgb(style.hex);
    const base = groundScreen(node); // devices sit on the floor
    const dim = hover && hover !== node.id ? 0.4 : 1;
    const phone = shape === "phone";
    const gx = phone ? 0.18 : 0.4;
    const gy = phone ? 0.13 : 0.18;
    const h = (phone ? 0.72 : 0.52) * TILE * dpr;
    const topY = isoBox(g, base, gx, gy, h, rgb, dim, style.glow);
    if (hover === node.id) {
      g.strokeStyle = css(hexToRgb(style.glow), 0.85);
      g.lineWidth = 2 * dpr;
      const axx = gx * TILE * dpr, axy = gx * VY * dpr;
      const ayx = -gy * TILE * dpr, ayy = gy * VY * dpr;
      const T = { x: base.x, y: base.y - h };
      g.beginPath();
      g.moveTo(T.x - axx - ayx, T.y - axy - ayy);
      g.lineTo(T.x + axx - ayx, T.y + axy - ayy);
      g.lineTo(T.x + axx + ayx, T.y + axy + ayy);
      g.lineTo(T.x - axx + ayx, T.y - axy + ayy);
      g.closePath();
      g.stroke();
    }
    return topY;
  }

  function drawLabel(g, node, topY) {
    const top = toScreen(node);
    const focused = hover === node.id;
    const dim = hover && !focused ? 0.4 : 1;
    // font/alignment are set once per frame in frame() before the label pass
    const anchorY = topY != null ? topY : top.y - VY * BLOCK * dpr;
    const ty = anchorY - 16 * dpr;
    const tw = g.measureText(node.label).width;
    const padX = 7 * dpr;
    const padY = 5 * dpr;
    // pill background
    const rx = top.x - tw / 2 - padX;
    const ry = ty - 8 * dpr - padY;
    const rw = tw + padX * 2;
    const rh = 16 * dpr + padY * 2;
    const rad = 6 * dpr;
    g.beginPath();
    g.moveTo(rx + rad, ry);
    g.arcTo(rx + rw, ry, rx + rw, ry + rh, rad);
    g.arcTo(rx + rw, ry + rh, rx, ry + rh, rad);
    g.arcTo(rx, ry + rh, rx, ry, rad);
    g.arcTo(rx, ry, rx + rw, ry, rad);
    g.closePath();
    g.fillStyle = css([8, 12, 20], (focused ? 0.92 : 0.7) * (dim < 1 ? 0.5 : 1));
    g.fill();
    if (focused) {
      g.strokeStyle = css(hexToRgb(KIND_STYLE[node.kind].glow), 0.8);
      g.lineWidth = 1.2 * dpr;
      g.stroke();
    }
    g.fillStyle = css([255, 255, 255], 0.96 * dim);
    g.fillText(node.label, top.x, ty);
  }

  /* ---- vertical vendor list beside a node (e.g. ESPs next to ESP) ------
     Each row is a small logo + name, stacked to the right of the block and
     vertically centred on it. Logo-less vendors get a small neutral dot. */
  function drawVendorList(g, node) {
    const vendors = NODE_VENDORS[node.id];
    if (!vendors) return;
    const dim = hover && hover !== node.id ? 0.4 : 1;
    const c = toScreen(node);
    const rowH = 24 * dpr;
    const icon = 13 * dpr;
    const x0 = c.x + TILE * BLOCK * dpr + 16 * dpr; // just right of the block
    const top0 = c.y - (vendors.length * rowH) / 2 + rowH / 2;

    g.save();
    g.textAlign = "left";
    g.textBaseline = "middle";
    g.font = `${11 * dpr}px "JetBrains Mono", ui-monospace, monospace`;
    for (let i = 0; i < vendors.length; i++) {
      const v = vendors[i];
      const y = top0 + i * rowH;
      if (v.logo) {
        const img = logoFor(v.logo);
        if (img.complete && img.naturalWidth) {
          const h = (icon * img.naturalHeight) / img.naturalWidth;
          g.globalAlpha = dim;
          g.drawImage(img, x0, y - h / 2, icon, h);
          g.globalAlpha = 1;
        }
      } else {
        // neutral marker for logo-less vendors
        g.fillStyle = css([138, 143, 150], 0.7 * dim);
        g.beginPath();
        g.roundRect(x0 + icon * 0.18, y - icon * 0.32, icon * 0.64, icon * 0.64, 2 * dpr);
        g.fill();
      }
      g.fillStyle = css([176, 186, 200], 0.95 * dim);
      g.fillText(v.name, x0 + icon + 8 * dpr, y);
    }
    g.restore();
  }

  /* ---- edges + hopping packets ---------------------------------------- */
  function drawEdge(g, edge, time) {
    const a = toScreen(nodeIndex[edge.from]);
    const b = toScreen(nodeIndex[edge.to]);
    const active = !hover || hover === edge.from || hover === edge.to;

    // faint connection path
    g.strokeStyle = css([150, 180, 230], active ? 0.4 : 0.1);
    g.lineWidth = 1.4 * dpr;
    g.setLineDash([3 * dpr, 5 * dpr]);
    g.beginPath();
    g.moveTo(a.x, a.y);
    g.lineTo(b.x, b.y);
    g.stroke();
    g.setLineDash([]);

    // hopping packets — linear travel with a bouncing arc, chicken-style.
    const dist = Math.hypot(b.x - a.x, b.y - a.y);
    const hops = Math.max(2, Math.round(dist / (TILE * 0.9 * dpr)));
    const hopH = 13 * dpr;
    const count = 2;
    const r = 3.2 * dpr;
    const glowR = r * 3.4;
    for (let i = 0; i < count; i++) {
      const u = (time * 0.16 + i / count) % 1;
      const x = a.x + (b.x - a.x) * u;
      const yLine = a.y + (b.y - a.y) * u;
      const y = yLine - Math.abs(Math.sin(u * Math.PI * hops)) * hopH;
      const pa = active ? 0.95 : 0.18;
      g.globalAlpha = pa;
      g.drawImage(GLOW, x - glowR, y - glowR, glowR * 2, glowR * 2);
      g.globalAlpha = 1;
      g.fillStyle = css([240, 248, 255], pa);
      g.beginPath();
      g.arc(x, y, r, 0, Math.PI * 2);
      g.fill();
    }
  }

  /* ---- main loop ------------------------------------------------------ */
  function frame(ts) {
    if (!running) return;
    raf = requestAnimationFrame(frame);
    if (!topo) return;
    if (t0 == null) t0 = ts;
    const time = (ts - t0) / 1000;

    ctx.clearRect(0, 0, canvas.width, canvas.height);
    drawZones(ctx);
    drawFloorBrand(ctx);
    if (shadowLayer) ctx.drawImage(shadowLayer, 0, 0);

    for (const edge of topo.edges) drawEdge(ctx, edge, time);

    // painter order is cached in sortedNodes (back→front)
    const tops = {};
    for (const node of sortedNodes) tops[node.id] = drawNode(ctx, node);
    // label font/alignment are constant — set once for the whole label pass
    ctx.font = `${12.5 * dpr}px "JetBrains Mono", ui-monospace, monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    for (const node of sortedNodes) drawLabel(ctx, node, tops[node.id]);
    for (const node of sortedNodes) drawVendorList(ctx, node);

    // hover hit-test (skipped while dragging)
    if (pointer.x >= 0 && !dragId) {
      hover = pickNode(pointer.x, pointer.y);
    }

    // report hover changes to React (for the explainer popup)
    const reportId = dragId ? null : hover;
    if (reportId !== lastReported) {
      lastReported = reportId;
      if (reportId) {
        const node = nodeIndex[reportId];
        const sp = toScreen(node);
        onHover({
          id: node.id,
          label: node.label,
          kind: node.kind,
          x: sp.x / dpr, // css px, relative to canvas/stage
          y: (sp.y - VY * BLOCK * dpr) / dpr, // top of the block
        });
      } else {
        onHover(null);
      }
    }
  }

  // Hit-test the node under a css-px point (front-to-back).
  function pickNode(px, py) {
    for (let i = sortedNodes.length - 1; i >= 0; i--) {
      const node = sortedNodes[i];
      const top = toScreen(node);
      const dx = (px * dpr - top.x) / dpr;
      const dy = (py * dpr - top.y) / dpr;
      if (Math.abs(dx) / (TILE * BLOCK * 1.4) + Math.abs(dy) / (VY * BLOCK * 2.2) < 1.3) {
        return node.id;
      }
    }
    return null;
  }

  const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
  const resort = () => {
    sortedNodes.sort((p, q) => p.x + p.y + p.z * 0.01 - (q.x + q.y + q.z * 0.01));
  };

  function onMove(ev) {
    const r = canvas.getBoundingClientRect();
    const px = ev.clientX - r.left;
    const py = ev.clientY - r.top;
    if (dragId) {
      // convert css-px delta → grid delta (z-independent, lift is constant)
      const dcx = px - lastPtr.x;
      const dcy = py - lastPtr.y;
      const A = dcx / TILE;
      const B = dcy / VY;
      const node = nodeIndex[dragId];
      node.x += (A + B) / 2;
      node.y += (B - A) / 2;
      // a node that belongs to a hosting zone stays inside it; others roam free
      const z = nodeZone[dragId];
      if (z) {
        node.x = clamp(node.x, z.minX + 0.4, z.maxX - 0.4);
        node.y = clamp(node.y, z.minY + 0.4, z.maxY - 0.4);
      }
      lastPtr = { x: px, y: py };
      resort();
      return;
    }
    pointer = { x: px, y: py };
  }
  function onLeave() {
    pointer = { x: -1, y: -1 };
    hover = null;
  }
  function onDown(ev) {
    const r = canvas.getBoundingClientRect();
    const px = ev.clientX - r.left;
    const py = ev.clientY - r.top;
    const hit = pickNode(px, py);
    if (!hit) return;
    dragId = hit;
    hover = hit;
    lastPtr = { x: px, y: py };
    canvas.style.cursor = "grabbing";
    canvas.setPointerCapture?.(ev.pointerId);
    ev.preventDefault();
  }
  function onUp() {
    if (!dragId) return;
    dragId = null;
    lastPtr = null;
    canvas.style.cursor = "grab";
    bakeShadows(); // re-ground the shadows at the dropped positions
  }

  function start() {
    if (running) return;
    running = true;
    t0 = null;
    raf = requestAnimationFrame(frame);
  }
  function stop() {
    running = false;
    cancelAnimationFrame(raf);
  }

  resize();
  canvas.style.cursor = "grab";
  const onResize = () => resize();
  window.addEventListener("resize", onResize);
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerleave", onLeave);
  canvas.addEventListener("pointerdown", onDown);
  canvas.addEventListener("pointerup", onUp);
  canvas.addEventListener("pointercancel", onUp);

  // Load the inbox2 mark and bake the floor brand (also rebake when the
  // Oxanium webfont finishes loading so the wordmark renders correctly).
  brandImg = new Image();
  brandImg.onload = () => bakeBrand();
  brandImg.onerror = () => bakeBrand(); // text-only fallback
  brandImg.src = "/assets/mark.png";
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => bakeBrand());
  }

  // Only animate while the board is actually on screen — otherwise a giant
  // high-DPI canvas keeps redrawing 60×/s and fights the page scroll.
  let io = null;
  if ("IntersectionObserver" in window) {
    io = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting) start();
        else stop();
      },
      { threshold: 0 },
    );
    io.observe(canvas);
  } else {
    start();
  }

  return {
    setTopology(next) {
      topo = next;
      nodeIndex = indexNodes(next);
      // static hosting-boundary rects (drive zone drawing, fit, drag clamp, brand)
      const pad = 0.9;
      zoneRects = (next.zones || []).map((z) => {
        const ns = z.nodes.map((id) => nodeIndex[id]).filter(Boolean);
        return {
          id: z.id,
          label: z.label,
          tint: z.tint,
          minX: Math.min(...ns.map((d) => d.x)) - pad,
          maxX: Math.max(...ns.map((d) => d.x)) + pad,
          minY: Math.min(...ns.map((d) => d.y)) - pad,
          maxY: Math.max(...ns.map((d) => d.y)) + pad,
        };
      });
      nodeZone = {};
      for (const z of zoneRects) {
        const def = (next.zones || []).find((d) => d.id === z.id);
        for (const id of def.nodes) nodeZone[id] = z;
      }
      // cache back→front paint order (resort owns the comparator)
      sortedNodes = [...next.nodes];
      resort();
      fit();
      lastReported = undefined; // re-emit hover next interaction
      start();
    },
    // Paste-ready n(...) lines for topologies.js, reflecting any dragging.
    exportLayout() {
      if (!topo) return "";
      const r2 = (v) => Math.round(v * 100) / 100;
      return topo.nodes
        .map((nd) => {
          const shape = nd.shape ? `, "${nd.shape}"` : "";
          return `    n("${nd.id}", "${nd.label}", KIND.${nd.kind}, ${r2(nd.x)}, ${r2(nd.y)}, ${nd.z}${shape}),`;
        })
        .join("\n");
    },
    destroy() {
      stop();
      io?.disconnect();
      window.removeEventListener("resize", onResize);
      canvas.removeEventListener("pointermove", onMove);
      canvas.removeEventListener("pointerleave", onLeave);
      canvas.removeEventListener("pointerdown", onDown);
      canvas.removeEventListener("pointerup", onUp);
      canvas.removeEventListener("pointercancel", onUp);
    },
  };
}
