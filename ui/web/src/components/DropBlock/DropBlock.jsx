import { useEffect, useRef, useCallback, useState } from 'react';
import useDropBlockStore, { STATUS, ghostCells } from '../../stores/dropBlockStore';
import { useDropBlockMuted, startMusic, stopMusic, setMusicTempo, sfx } from '../../lib/dropBlockAudio';
import { isTauri } from '../../lib/tauri';
import {
  COLS, ROWS, BOMB, PACMAN, PIECE, COLORS, SHAPES, pieceCells, gravityMs,
} from './engine';
import styles from './DropBlock.module.css';

// Timing constants (ms).
const LOCK_DELAY = 500;       // grace period once a piece is resting
const MAX_LOCK_RESETS = 15;   // cap move/rotate lock-delay resets (anti-stall)

// Accelerating auto-repeat for held movement keys (←/→/↓). The first repeat
// comes after REPEAT_DELAY; each repeat after that is 25% faster than the last
// (interval ×= REPEAT_ACCEL) down to REPEAT_MIN.
const REPEAT_ACCEL = 0.75;
const REPEAT_KEYS = { ArrowLeft: 1, ArrowRight: 1, ArrowDown: 1 };
// Auto-repeat timing scales with level: as gravity speeds up, the delay before
// auto-shift kicks in (DAS) and the fastest repeat interval (ARR floor) both
// shrink, so the controls get snappier exactly when you need to react faster.
// Tuned a touch slower overall so the keys feel a little less twitchy, and the
// high-speed floor kept higher so fast levels don't overshoot the target column.
const repeatDelay = (level) => Math.max(75, 150 - (level - 1) * 8); // initial delay (ms)
const repeatFloor = (level) => Math.max(23, 27 - (level - 1) * 0.8); // fastest interval (ms)

// Line-clear animation: cleared rows blink (flash), then the rows above slide
// down into the gaps before the board is committed.
const CLEAR_FLASH = 280;
const CLEAR_DROP = 150;
const CLEAR_TOTAL = CLEAR_FLASH + CLEAR_DROP;
const CLEAR_MIN_ALPHA = 0.2; // cleared rows softly dim to 20% (no harsh blink)
const GHOST_FILL_ALPHA = 0.16; // ghost: faded color fill
const GHOST_LINE_ALPHA = 0.85; // ghost: outline in the piece's colour
const GHOST_SPRITE_ALPHA = 0.3; // ghost: faded sprite (bomb / Pac-Man landing preview)

// Pop-art sound-effect stickers. A small clear (1–3 lines) shows a random word
// from the pool for a bit of surprise; a four-line clear always lands the big
// BAM. Files live in public/dropblock/<name>.png.
const SMALL_BURSTS = ['pow', 'zap', 'boom', 'wham', 'zok'];
const BIG_BURST = 'bam';
// When the lowest cleared row is within the top few rows there's no room to place
// the burst two rows above it, so it floats above the playing area instead.
const TOP_ROWS_LIMIT = 3;

// Bomb detonation timing (ms): beams shoot to the walls, the row+column cells
// vaporize, then the beams fade out.
const BLAST_BEAM = 150;
const BLAST_TOTAL = 440;
// After the beam, the columns collapse — surviving blocks fall to fill the gaps.
const FALL_TOTAL = 220;
// Once a power-up (bomb/Pac-Man) has fully resolved, hold this long on the settled
// board before the next piece spawns — a small beat so the result reads.
const SPAWN_DELAY = 500;

// Pac-Man frenzy timing. The eating window is ~6s, shrinking a little as the game
// speeds up; the roaming step cadence (and so how fast it chomps) gets quicker
// with the level too. Both "go faster as the game speeds up".
const PAC_WINDOW = (level) => Math.max(2600, 4000 - (level - 1) * 160); // ms of eating time
const PAC_STEP = (level) => Math.max(70, 150 - (level - 1) * 8);        // ms per cell of travel
const PAC_CHOMP = 100; // ms per chomp-animation frame

// Resolve an asset URL. Normally the public path is used as-is; when embedded in
// a native WebView (no HTTP origin) the host inlines the sprites and exposes them
// as data URIs on `window.__DROPBLOCK_ASSETS`, keyed by their public path.
const asset = (p) => (typeof window !== 'undefined' && window.__DROPBLOCK_ASSETS && window.__DROPBLOCK_ASSETS[p]) || p;
const logoSrc = asset('/logo-mark.png');

// The bomb sprite — a single shared image, loaded once.
const bombSprite = new Image();
bombSprite.src = asset('/dropblock/bomb.png');

// The Pac-Man chomp frames (mouth open → mid → closed), loaded once. The chomp
// cycles open→mid→closed→mid; the sprite faces right and is rotated per heading.
const PAC_FRAME_NAMES = ['open', 'mid', 'closed'];
const pacSprites = PAC_FRAME_NAMES.map((n) => { const im = new Image(); im.src = asset(`/dropblock/pacman-${n}.png`); return im; });
const PAC_CHOMP_CYCLE = [0, 1, 2, 1];
const PAC_ROT = { right: 0, down: Math.PI / 2, left: Math.PI, up: -Math.PI / 2 };

// ── Canvas drawing helpers ──────────────────────────────────────────────────

// Groovebox skin: pastel keycaps on a black well with the theme's violet grid.
// Read from <html data-theme-variant> once per frame by the draw passes.
let groove = false;
const syncSkin = () => { groove = document.documentElement.getAttribute('data-theme-variant') === 'groovebox'; };
const GROOVE_COLORS = {
  [PIECE.I]: '#44c2b3', [PIECE.O]: '#f0b545', [PIECE.T]: '#a68cf0', [PIECE.S]: '#5fd68a',
  [PIECE.Z]: '#f2785c', [PIECE.J]: '#f0a3bd', [PIECE.L]: '#ece7dc',
};
const pieceColor = (type) => (groove && GROOVE_COLORS[type]) || COLORS[type];

// One keycap: a darker skirt, the cap on top of it, a top highlight and a
// legend slot — the synth's keys, scaled to a cell.
function drawKeycap(ctx, px, py, size, color) {
  const pad = Math.max(1, size * 0.05);
  const r = size * 0.22;
  const w = size - pad * 2;
  ctx.fillStyle = color;
  ctx.beginPath(); ctx.roundRect(px + pad, py + pad, w, w, r); ctx.fill();
  ctx.fillStyle = 'rgba(0,0,0,0.38)';
  ctx.beginPath(); ctx.roundRect(px + pad, py + pad, w, w, r); ctx.fill();
  ctx.fillStyle = color;
  ctx.beginPath(); ctx.roundRect(px + pad, py + pad, w, w * 0.84, r); ctx.fill();
  ctx.fillStyle = 'rgba(255,255,255,0.35)';
  ctx.fillRect(px + pad + r, py + pad + 1, w - r * 2, Math.max(1, size * 0.04));
  ctx.fillStyle = 'rgba(20,20,22,0.28)';
  ctx.beginPath(); ctx.roundRect(px + size * 0.32, py + size * 0.24, size * 0.36, size * 0.16, size * 0.08); ctx.fill();
}

// A single beveled block — flat fill plus a light top/left highlight and a dark
// bottom/right shadow, in the project's glassy Vista-Aero spirit. The caller sets
// ctx.globalAlpha for the ghost (a faded copy of the piece).
function drawBlock(ctx, px, py, size, color) {
  if (groove) { drawKeycap(ctx, px, py, size, color); return; }
  const g = size * 0.16;
  ctx.fillStyle = color;
  ctx.fillRect(px, py, size, size);
  // top + left highlight
  ctx.fillStyle = 'rgba(255,255,255,0.45)';
  ctx.fillRect(px, py, size, g);
  ctx.fillRect(px, py, g, size);
  // bottom + right shadow
  ctx.fillStyle = 'rgba(0,0,0,0.35)';
  ctx.fillRect(px, py + size - g, size, g);
  ctx.fillRect(px + size - g, py, g, size);
  // crisp edge
  ctx.strokeStyle = 'rgba(0,0,0,0.55)';
  ctx.lineWidth = 1;
  ctx.strokeRect(px + 0.5, py + 0.5, size - 1, size - 1);
}

// Landing preview: an outline in the piece's colour with a faint colour fill.
function drawGhost(ctx, px, py, size, color) {
  if (groove) {
    // Outlined key, like the guidebook's line art.
    const inset = size * 0.1;
    ctx.globalAlpha = 0.85;
    ctx.strokeStyle = color;
    ctx.lineWidth = Math.max(1.5, size * 0.07);
    ctx.beginPath(); ctx.roundRect(px + inset, py + inset, size - inset * 2, size - inset * 2, size * 0.2); ctx.stroke();
    ctx.globalAlpha = 1;
    return;
  }
  ctx.globalAlpha = GHOST_FILL_ALPHA;
  ctx.fillStyle = color;
  ctx.fillRect(px, py, size, size);
  ctx.globalAlpha = GHOST_LINE_ALPHA;
  ctx.strokeStyle = color;
  const inset = size * 0.08;
  ctx.lineWidth = Math.max(1.5, size * 0.08);
  ctx.strokeRect(px + inset, py + inset, size - inset * 2, size - inset * 2);
  ctx.globalAlpha = 1;
}

// Size a canvas's backing store to its CSS box at the device pixel ratio and
// return the drawing context already scaled to CSS pixels.
function prepCanvas(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w, h };
}

// Tight bounding box of a piece's spawn shape, for centring previews.
function shapeBounds(type) {
  const shape = SHAPES[type][0];
  let minR = 99, maxR = -1, minC = 99, maxC = -1;
  for (let r = 0; r < shape.length; r++) {
    for (let c = 0; c < shape[r].length; c++) {
      if (shape[r][c]) {
        minR = Math.min(minR, r); maxR = Math.max(maxR, r);
        minC = Math.min(minC, c); maxC = Math.max(maxC, c);
      }
    }
  }
  return { minR, maxR, minC, maxC, rows: maxR - minR + 1, cols: maxC - minC + 1 };
}

// Draw one block centred inside a box (used for hold + next previews).
function drawPreview(ctx, type, boxX, boxY, boxW, boxH) {
  const b = shapeBounds(type);
  const cell = Math.min(boxW / 4.5, boxH / 4.5);
  const offX = boxX + (boxW - b.cols * cell) / 2;
  const offY = boxY + (boxH - b.rows * cell) / 2;
  const shape = SHAPES[type][0];
  for (let r = b.minR; r <= b.maxR; r++) {
    for (let c = b.minC; c <= b.maxC; c++) {
      if (shape[r][c]) {
        drawBlock(ctx, offX + (c - b.minC) * cell, offY + (r - b.minR) * cell, cell, pieceColor(type));
      }
    }
  }
}

// Cheap deterministic pseudo-random in [0,1) from an integer seed — used to make
// sparks/lightning twinkle without Math.random (which would change every frame).
function rand01(seed) {
  const s = Math.sin(seed) * 43758.5453;
  return s - Math.floor(s);
}

// Draw the bomb sprite in a cell with a ring of twinkling electric sparks.
// Drawn 20% larger than the cell (centred, so it slightly overhangs) for impact.
// In `ghost` mode it's a faded, still sprite (no pulse/sparks) for the landing
// preview.
function drawBomb(ctx, px, py, size, now, ghost = false) {
  const pulse = ghost ? 1 : 1 + 0.05 * Math.sin(now * 0.012);
  const s = size * 1.2 * pulse;
  const off = (size - s) / 2;
  if (ghost) ctx.globalAlpha = GHOST_SPRITE_ALPHA;
  if (bombSprite.complete && bombSprite.naturalWidth) {
    ctx.drawImage(bombSprite, px + off, py + off, s, s);
  } else {
    ctx.fillStyle = '#0b0f1a';
    ctx.beginPath(); ctx.arc(px + size / 2, py + size / 2, size * 0.42, 0, Math.PI * 2); ctx.fill();
  }
  if (ghost) { ctx.globalAlpha = 1; return; } // a faded landing sprite — no live sparks
  const cx = px + size / 2, cy = py + size / 2;
  const tq = Math.floor(now / 45); // re-roll sparks ~22×/sec so they twinkle
  ctx.save();
  ctx.globalCompositeOperation = 'lighter';
  for (let i = 0; i < 5; i++) {
    const rnd = rand01(tq + i * 12.9898);
    const ang = (i / 5) * Math.PI * 2 + rnd * 1.5;
    const dist = size * (0.42 + rnd * 0.22);
    const len = size * (0.1 + rnd * 0.12);
    const x0 = cx + Math.cos(ang) * dist, y0 = cy + Math.sin(ang) * dist;
    const x1 = x0 + Math.cos(ang) * len, y1 = y0 + Math.sin(ang) * len;
    ctx.strokeStyle = i % 2 ? 'rgba(120,220,255,0.9)' : 'rgba(255,255,255,0.85)';
    ctx.lineWidth = Math.max(1, size * 0.04);
    ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); ctx.stroke();
    ctx.fillStyle = 'rgba(180,235,255,0.9)';
    ctx.beginPath(); ctx.arc(x1, y1, Math.max(1, size * 0.03), 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}

// Draw the animated Pac-Man sprite in a cell, facing `dir` and chomping. While
// `flashing` (the eating frenzy) it pulses a warm glow and gently strobes so it
// reads as "powered up". In `ghost` mode it's a faded, still mouth-closed sprite
// for the landing preview. Falls back to a procedural arc if the sprite is missing.
function drawPacman(ctx, px, py, size, now, dir, flashing, ghost = false) {
  const cx = px + size / 2, cy = py + size / 2;
  const img = ghost ? pacSprites[2] // closed (full disc) reads best as a still ghost
    : pacSprites[PAC_CHOMP_CYCLE[Math.floor(now / PAC_CHOMP) % PAC_CHOMP_CYCLE.length]];
  const s = size * 0.6; // a compact 60% of the cell
  ctx.save();
  ctx.translate(cx, cy);
  ctx.rotate(PAC_ROT[dir] || 0);
  if (ghost) {
    ctx.globalAlpha = GHOST_SPRITE_ALPHA;
  } else if (flashing) {
    const pulse = 0.5 + 0.5 * Math.abs(Math.sin(now * 0.018));
    ctx.globalAlpha = 0.62 + 0.38 * pulse;
    ctx.shadowColor = 'rgba(255,228,74,0.95)';
    ctx.shadowBlur = size * (0.28 + 0.4 * pulse);
  }
  if (img && img.complete && img.naturalWidth) {
    ctx.drawImage(img, -s / 2, -s / 2, s, s);
  } else {
    // Procedural fallback — a yellow disc with an animated wedge mouth (opens +x).
    const r = size * 0.3;
    const open = [0.30, 0.16, 0.02, 0.16][Math.floor(now / PAC_CHOMP) % 4] * Math.PI;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.arc(0, 0, r, open, Math.PI * 2 - open);
    ctx.closePath();
    ctx.fillStyle = '#ffe24a';
    ctx.fill();
    ctx.strokeStyle = 'rgba(150,115,0,0.6)'; ctx.lineWidth = Math.max(1, size * 0.02); ctx.stroke();
    ctx.beginPath(); ctx.arc(r * 0.05, -r * 0.5, r * 0.13, 0, Math.PI * 2); ctx.fillStyle = '#10131a'; ctx.fill();
  }
  ctx.restore();
}

// Draw the four electric beams of a bomb detonation from its origin cell. The
// row+column cells are vaporized by the caller; this is the beam VFX on top.
function drawBlastBeams(ctx, geom, anim, now) {
  const { ox, oy, cell, gridW, gridH } = geom;
  const { col, row, elapsed } = anim;
  const cx = ox + (col + 0.5) * cell;
  const cy = oy + (row + 0.5) * cell;
  const p = elapsed / BLAST_TOTAL;
  const reach = Math.min(1, elapsed / BLAST_BEAM);
  const fade = p < 0.45 ? 1 : Math.max(0, 1 - (p - 0.45) / 0.55);
  if (fade <= 0) return;

  const left = ox, right = ox + gridW, top = oy, bottom = oy + gridH;
  const hx0 = cx - (cx - left) * reach, hx1 = cx + (right - cx) * reach;
  const vy0 = cy - (cy - top) * reach, vy1 = cy + (bottom - cy) * reach;

  ctx.save();
  ctx.globalCompositeOperation = 'lighter';
  // Stacked beam layers: wide cyan glow → mid → thin white-hot core.
  const layers = [
    { t: 0.95, a: 0.20 * fade, rgb: '90,200,255' },
    { t: 0.50, a: 0.35 * fade, rgb: '150,225,255' },
    { t: 0.22, a: 0.95 * fade, rgb: '255,255,255' },
  ];
  for (const L of layers) {
    const th = cell * L.t;
    ctx.fillStyle = `rgba(${L.rgb},${L.a})`;
    ctx.fillRect(hx0, cy - th / 2, hx1 - hx0, th);
    ctx.fillRect(cx - th / 2, vy0, th, vy1 - vy0);
  }
  // Electric jitter — jagged lightning along each axis.
  const tq = Math.floor(now / 30);
  ctx.strokeStyle = `rgba(220,245,255,${0.7 * fade})`;
  ctx.lineWidth = Math.max(1, cell * 0.06);
  const bolt = (a, b, horiz) => {
    ctx.beginPath();
    const steps = 12;
    for (let i = 0; i <= steps; i++) {
      const f = i / steps;
      const offv = (rand01(tq + i * 7.13 + (horiz ? 0 : 99)) - 0.5) * cell * 0.5;
      if (horiz) { const x = a + (b - a) * f; i ? ctx.lineTo(x, cy + offv) : ctx.moveTo(x, cy + offv); }
      else { const y = a + (b - a) * f; i ? ctx.lineTo(cx + offv, y) : ctx.moveTo(cx + offv, y); }
    }
    ctx.stroke();
  };
  bolt(hx0, hx1, true);
  bolt(vy0, vy1, false);
  // Bright origin flash early in the blast.
  const flash = Math.max(0, 1 - p / 0.4) * fade;
  if (flash > 0) {
    const rg = ctx.createRadialGradient(cx, cy, 0, cx, cy, cell * 1.7);
    rg.addColorStop(0, `rgba(255,255,255,${0.9 * flash})`);
    rg.addColorStop(0.4, `rgba(150,220,255,${0.5 * flash})`);
    rg.addColorStop(1, 'rgba(120,200,255,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(cx, cy, cell * 1.7, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}

// Small inline speaker glyph for the mute toggle (on = waves, muted = slash).
function SpeakerIcon({ muted }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M11 5 L6 9 H3 v6 h3 l5 4 Z" fill="currentColor" fillOpacity="0.25" />
      {muted ? (
        <path d="M16 9 L22 15 M22 9 L16 15" />
      ) : (
        <>
          <path d="M15.5 8.5 a5 5 0 0 1 0 7" />
          <path d="M18.5 6 a9 9 0 0 1 0 12" />
        </>
      )}
    </svg>
  );
}

export default function DropBlock({ iconSrc } = {}) {
  const status = useDropBlockStore((s) => s.status);
  const score = useDropBlockStore((s) => s.score);
  const lines = useDropBlockStore((s) => s.lines);
  const level = useDropBlockStore((s) => s.level);
  const best = useDropBlockStore((s) => s.best);
  const beat = useDropBlockStore((s) => s.beat);
  const clearing = useDropBlockStore((s) => s.clearing);
  const pacActive = useDropBlockStore((s) => !!s.pac);
  const { muted, toggle: toggleMute } = useDropBlockMuted();

  // Comic sound-effect burst (POW for 1–3 lines, BAM for a quad). A bumped key
  // remounts the <img> so its appear animation restarts on every clear.
  const [burst, setBurst] = useState(null);
  const burstSeq = useRef(0);

  // Debug mode (toggled with `~`): exposes the hidden `b` key that spawns a bomb
  // next. The ref is read live in the key handler; the state drives the badge.
  const [debug, setDebug] = useState(false);
  const debugRef = useRef(false);

  // The right SFX for whatever a lock produced: a bomb detonation, a four-line
  // quad fanfare, a smaller line clear, or just the impact.
  const playLockSfx = useCallback(() => {
    const st = useDropBlockStore.getState();
    if (st.blast) { sfx('bomb'); return; }
    sfx('whop');
    if (st.clearing) sfx(st.clearing.rows.length >= 4 ? 'quad' : 'clear');
  }, []);

  const rootRef = useRef(null);
  const wellRef = useRef(null);
  const holdRef = useRef(null);
  const nextRef = useRef(null);

  // Lock-delay state shared with the key handler. The gravity accumulator lives
  // locally inside the loop so every PLAYING session starts with clean timing.
  const lockAccRef = useRef(0);
  const lockResetsRef = useRef(0);
  // Held movement keys for accelerating auto-repeat: key -> { nextAt, interval }.
  const heldRef = useRef({});

  // Reset the lock-delay timer on a successful move/rotate (capped) so a piece
  // can be slid/spun along the floor before it settles. Shared by the key
  // handler and the auto-repeat loop.
  const resetLock = useCallback(() => {
    if (!useDropBlockStore.getState().canMoveDown() && lockResetsRef.current < MAX_LOCK_RESETS) {
      lockAccRef.current = 0;
      lockResetsRef.current += 1;
    }
  }, []);

  // ── Render the well + previews (imperative, every frame) ──────────────────
  useEffect(() => {
    if (status === STATUS.IDLE) return;

    // Per-session loop state — local so it can never leak between games or
    // stack up across re-runs. `cancelled` guarantees an orphaned frame (e.g.
    // from a StrictMode double-invoke) dies instead of double-stepping gravity.
    let cancelled = false;
    let raf = 0;
    let acc = 0;       // gravity accumulator (ms)
    let last = 0;      // timestamp of previous frame
    let primed = false; // becomes true once we have a baseline timestamp
    let clearStart = null; // timestamp the current line-clear animation began
    let blastStart = null; // timestamp the current bomb beam animation began
    let fallStart = null;  // timestamp the post-blast gravity collapse began
    let pacStart = null;   // timestamp the current Pac-Man frenzy began
    let pacSteps = 0;      // cells the Pac-Man has advanced this frenzy
    let spawnHoldStart = null; // timestamp the post-power-up spawn hold began
    heldRef.current = {}; // clear any stuck held-key repeats from a prior session

    // `clearAnim` is { rows, elapsed } while a line-clear is animating;
    // `blastAnim` is { col, row, elapsed } while a bomb's beams fire;
    // `fallAnim` is { elapsed } while the post-blast columns collapse;
    // `pacAnim` is { elapsed, total } while a Pac-Man frenzy is roaming.
    const drawWell = (clearAnim, blastAnim, fallAnim, pacAnim, now) => {
      const canvas = wellRef.current;
      if (!canvas) return;
      const { ctx, w, h } = prepCanvas(canvas);
      const cell = Math.floor(Math.min(w / COLS, h / ROWS));
      const gridW = cell * COLS;
      const gridH = cell * ROWS;
      const ox = (w - gridW) / 2;
      const oy = (h - gridH) / 2;

      syncSkin();
      ctx.clearRect(0, 0, w, h);
      // translucent well so the chosen background photo shows through
      // (Groovebox: the black island, opaque)
      ctx.fillStyle = groove ? '#0a0a0b' : 'rgba(8, 12, 20, 0.55)';
      ctx.fillRect(ox, oy, gridW, gridH);

      // faint grid (Groovebox: the theme's violet grid)
      ctx.strokeStyle = groove ? 'rgba(148,121,216,0.22)' : 'rgba(255,255,255,0.06)';
      ctx.lineWidth = 1;
      for (let c = 0; c <= COLS; c++) {
        ctx.beginPath();
        ctx.moveTo(ox + c * cell + 0.5, oy);
        ctx.lineTo(ox + c * cell + 0.5, oy + gridH);
        ctx.stroke();
      }
      for (let r = 0; r <= ROWS; r++) {
        ctx.beginPath();
        ctx.moveTo(ox, oy + r * cell + 0.5);
        ctx.lineTo(ox + gridW, oy + r * cell + 0.5);
        ctx.stroke();
      }

      const st = useDropBlockStore.getState();

      // Line-clear animation parameters.
      const clearingRows = clearAnim ? new Set(clearAnim.rows) : null;
      const inDrop = clearAnim && clearAnim.elapsed >= CLEAR_FLASH;
      const dropT = inDrop ? Math.min(1, (clearAnim.elapsed - CLEAR_FLASH) / CLEAR_DROP) : 0;
      // Soft fade: cleared rows ease from full down to 20% opacity over the flash
      // phase, then vanish as the stack slides down.
      let flashAlpha = 1;
      if (clearAnim && !inDrop) {
        const tf = clearAnim.elapsed / CLEAR_FLASH;
        const ease = tf * tf * (3 - 2 * tf);
        flashAlpha = 1 - (1 - CLEAR_MIN_ALPHA) * ease;
      }

      // During the collapse, the moved blocks are drawn (animated) separately —
      // skip their settled positions here so they don't double up.
      const fallSkip = fallAnim && st.fall ? new Set(st.fall.map((f) => `${f.x},${f.to}`)) : null;

      // settled blocks
      for (let r = 0; r < ROWS; r++) {
        for (let c = 0; c < COLS; c++) {
          const t = st.board[r][c];
          if (!t) continue;
          if (fallSkip && fallSkip.has(`${c},${r}`)) continue;
          // Bomb blast: cells in the bomb's row or column vaporize — a white-hot
          // flash, then they shrink and fade out under the beams.
          if (blastAnim && (c === blastAnim.col || r === blastAnim.row)) {
            const bp = blastAnim.elapsed / BLAST_TOTAL;
            const a = Math.max(0, 1 - bp * 1.1);
            if (a > 0) {
              const shrink = 0.35 + 0.65 * Math.max(0, 1 - bp * 1.4);
              const inset = cell * (1 - shrink) / 2;
              ctx.globalAlpha = a;
              drawBlock(ctx, ox + c * cell + inset, oy + r * cell + inset, cell * shrink, pieceColor(t));
              if (bp < 0.35) {
                ctx.fillStyle = `rgba(255,255,255,${(0.35 - bp) / 0.35})`;
                ctx.fillRect(ox + c * cell, oy + r * cell, cell, cell);
              }
              ctx.globalAlpha = 1;
            }
            continue;
          }
          if (clearingRows && clearingRows.has(r)) {
            // Cleared rows: softly fade toward 20% opacity, then disappear as the
            // rows above slide down over them.
            if (inDrop) continue;
            ctx.globalAlpha = flashAlpha;
            drawBlock(ctx, ox + c * cell, oy + r * cell, cell, pieceColor(t));
            ctx.globalAlpha = 1;
            continue;
          }
          // Rows above a cleared line slide down by however many cleared lines
          // sit below them, eased over the drop phase.
          let drawRow = r;
          if (inDrop) {
            let shift = 0;
            for (const cr of clearAnim.rows) if (cr > r) shift += 1;
            drawRow = r + shift * dropT;
          }
          drawBlock(ctx, ox + c * cell, oy + drawRow * cell, cell, pieceColor(t));
        }
      }

      // ghost + active piece (not while topped out, mid-clear or mid-blast)
      if (st.status !== STATUS.OVER && st.piece && !clearAnim && !blastAnim) {
        if (st.piece.type === BOMB) {
          // Faded bomb ghost where it will land/detonate, then the live bomb.
          for (const { x, y } of ghostCells(st.board, st.piece)) {
            if (y >= 0) drawBomb(ctx, ox + x * cell, oy + y * cell, cell, now, true);
          }
          const { x, y } = pieceCells(st.piece)[0];
          if (y >= 0) drawBomb(ctx, ox + x * cell, oy + y * cell, cell, now);
        } else if (st.piece.type === PACMAN) {
          // Faded Pac-Man ghost where it will land, then the live one chomping
          // downward (the way it's "eating downwards").
          for (const { x, y } of ghostCells(st.board, st.piece)) {
            if (y >= 0) drawPacman(ctx, ox + x * cell, oy + y * cell, cell, now, 'down', false, true);
          }
          const { x, y } = pieceCells(st.piece)[0];
          if (y >= 0) drawPacman(ctx, ox + x * cell, oy + y * cell, cell, now, 'down', false);
        } else {
          const color = pieceColor(st.piece.type);
          // Ghost = outline in the piece's colour with a faint colour fill.
          for (const { x, y } of ghostCells(st.board, st.piece)) {
            if (y >= 0) drawGhost(ctx, ox + x * cell, oy + y * cell, cell, color);
          }
          for (const { x, y } of pieceCells(st.piece)) {
            if (y >= 0) drawBlock(ctx, ox + x * cell, oy + y * cell, cell, color);
          }
        }
      }

      // Post-blast collapse: surviving blocks fall from their old row to the
      // settled row with an accelerating (gravity-like) ease.
      if (fallAnim && st.fall) {
        const e = Math.min(1, fallAnim.elapsed / FALL_TOTAL);
        const k = e * e;
        for (const f of st.fall) {
          const dr = f.from + (f.to - f.from) * k;
          drawBlock(ctx, ox + f.x * cell, oy + dr * cell, cell, pieceColor(f.type));
        }
      }

      // Bomb beams drawn on top of the vaporizing cells.
      if (blastAnim) drawBlastBeams(ctx, { ox, oy, cell, gridW, gridH }, blastAnim, now);

      // Roaming, flashing Pac-Man + a depleting countdown ring around it.
      if (pacAnim && st.pac) {
        const pcx = ox + (st.pac.x + 0.5) * cell;
        const pcy = oy + (st.pac.y + 0.5) * cell;
        const remain = Math.max(0, 1 - pacAnim.elapsed / pacAnim.total);
        // The ring quickens its flash as time runs out.
        const urgent = remain < 0.3;
        ctx.save();
        ctx.strokeStyle = urgent && Math.floor(now / 120) % 2
          ? 'rgba(255,90,90,0.95)' : 'rgba(255,228,74,0.9)';
        ctx.lineWidth = Math.max(1.5, cell * 0.07);
        ctx.beginPath();
        ctx.arc(pcx, pcy, cell * 0.44, -Math.PI / 2, -Math.PI / 2 + remain * Math.PI * 2);
        ctx.stroke();
        ctx.restore();
        drawPacman(ctx, ox + st.pac.x * cell, oy + st.pac.y * cell, cell, now, st.pac.dir, true);
      }
    };

    const drawSide = (canvas, type) => {
      if (!canvas) return;
      syncSkin();
      const { ctx, w, h } = prepCanvas(canvas);
      ctx.clearRect(0, 0, w, h);
      if (type) drawPreview(ctx, type, 0, 0, w, h);
    };

    // Bomb preview in the Next panel (used when a bomb is armed via debug `b`).
    const drawSideBomb = (canvas, now) => {
      if (!canvas) return;
      const { ctx, w, h } = prepCanvas(canvas);
      ctx.clearRect(0, 0, w, h);
      const size = Math.min(w, h) * 0.6;
      drawBomb(ctx, (w - size) / 2, (h - size) / 2, size, now);
    };

    // Pac-Man preview in the Next panel (used when armed via debug `p`). Pass the
    // full box as the cell so the 60%-of-cell sprite reads at a good preview size.
    const drawSidePacman = (canvas, now) => {
      if (!canvas) return;
      const { ctx, w, h } = prepCanvas(canvas);
      ctx.clearRect(0, 0, w, h);
      const size = Math.min(w, h);
      drawPacman(ctx, (w - size) / 2, (h - size) / 2, size, now, 'right', false);
    };

    const frame = (now) => {
      if (cancelled) return;
      raf = requestAnimationFrame(frame);
      const st = useDropBlockStore.getState();
      let clearAnim = null;
      let blastAnim = null;
      let fallAnim = null;
      let pacAnim = null;

      if (st.status === STATUS.PLAYING && st.pac) {
        // A Pac-Man frenzy is live — gravity is paused. It roams one cell every
        // PAC_STEP(level), chomping (and scoring) whatever it touches; after
        // PAC_WINDOW(level) the frenzy ends and the columns collapse via finishPac.
        if (pacStart == null) { pacStart = now; pacSteps = 0; }
        const elapsed = now - pacStart;
        const total = PAC_WINDOW(st.level);
        const due = Math.floor(elapsed / PAC_STEP(st.level));
        let guard = 0;
        while (pacSteps < due && guard < 8) {
          guard += 1; pacSteps += 1;
          if (useDropBlockStore.getState().pacStep()) sfx('chomp');
        }
        if (elapsed >= total) {
          useDropBlockStore.getState().finishPac();
          pacStart = null;
        } else {
          pacAnim = { elapsed, total };
        }
        primed = false; // re-sync the gravity baseline once play continues
      } else if (st.status === STATUS.PLAYING && (st.blast || st.fall)) {
        // A bomb is detonating — gravity is paused. First the beams fire and the
        // cross cells vaporize; collapseBomb() then clears them and settles the
        // columns; the surviving blocks animate their fall; finishFall() spawns next.
        if (st.blast) {
          if (blastStart == null) blastStart = now;
          const elapsed = now - blastStart;
          if (elapsed >= BLAST_TOTAL) {
            useDropBlockStore.getState().collapseBomb();
            blastStart = null;
          } else {
            blastAnim = { col: st.blast.col, row: st.blast.row, elapsed };
          }
        }
        // Pick up the collapse in the same frame the beam ends, so there's no
        // one-frame snap to the settled board before the fall begins.
        const sf = useDropBlockStore.getState();
        if (!blastAnim && sf.fall) {
          if (fallStart == null) fallStart = now;
          const elapsed = now - fallStart;
          if (elapsed >= FALL_TOTAL) {
            useDropBlockStore.getState().finishFall();
            fallStart = null;
          } else {
            fallAnim = { elapsed };
          }
        }
        primed = false; // re-sync the gravity baseline once play continues
      } else if (st.status === STATUS.PLAYING && st.pendingSpawn) {
        // A bomb/Pac-Man has fully resolved — hold a short beat on the settled
        // board, then spawn the next piece.
        if (spawnHoldStart == null) spawnHoldStart = now;
        if (now - spawnHoldStart >= SPAWN_DELAY) {
          useDropBlockStore.getState().spawnNext();
          spawnHoldStart = null;
        }
        primed = false; // re-sync the gravity baseline once play continues
      } else if (st.status === STATUS.PLAYING && st.clearing) {
        // A line-clear is animating — gravity is paused, the rows flash then the
        // stack above slides down; commit the board when the animation ends.
        if (clearStart == null) clearStart = now;
        const elapsed = now - clearStart;
        if (elapsed >= CLEAR_TOTAL) {
          useDropBlockStore.getState().finishClear();
          clearStart = null;
        } else {
          clearAnim = { rows: st.clearing.rows, elapsed };
        }
        primed = false; // re-sync the gravity baseline once play continues
      } else if (st.status === STATUS.PLAYING) {
        // Establish a baseline on the first playing frame so the initial dt is
        // ~0 (never a giant gap that would drop the piece several rows at once).
        if (!primed) { primed = true; last = now; }
        let dt = now - last;
        last = now;
        if (dt > 100) dt = 100; // clamp after a tab-out / stall

        // Natural gravity — one row every gravityMs(level), capped per frame so
        // a stall can never make a piece appear to drop instantly. Power-ups (the
        // bomb and Pac-Man) come in much faster for an extra jolt of urgency:
        // two compounded 30% boosts (1.3 × 1.3 ≈ 1.69× fall speed).
        const isPowerUp = st.piece && (st.piece.type === BOMB || st.piece.type === PACMAN);
        const g = isPowerUp ? gravityMs(st.level) / 1.69 : gravityMs(st.level);
        acc += dt;
        let steps = 0;
        while (acc >= g && steps < 2) {
          acc -= g;
          steps += 1;
          if (!useDropBlockStore.getState().stepDown(false)) { acc = 0; break; }
        }
        if (acc > g) acc = g; // don't bank surplus time across frames

        // Accelerating auto-repeat for held movement keys: each repeat is 30%
        // faster than the last, down to a level-scaled floor (snappier at speed).
        const held = heldRef.current;
        const floor = repeatFloor(st.level);
        for (const key in held) {
          const h = held[key];
          let guard = 0;
          while (now >= h.nextAt && guard < 12) {
            guard += 1;
            const s = useDropBlockStore.getState();
            if (key === 'ArrowLeft') { if (s.moveLeft()) { resetLock(); sfx('swoosh', 0.4); } }
            else if (key === 'ArrowRight') { if (s.moveRight()) { resetLock(); sfx('swoosh', 0.4); } }
            else if (key === 'ArrowDown') { s.stepDown(true); }
            h.interval = Math.max(floor, h.interval * REPEAT_ACCEL);
            h.nextAt += h.interval;
          }
        }

        if (useDropBlockStore.getState().canMoveDown()) {
          lockAccRef.current = 0;
          lockResetsRef.current = 0;
        } else {
          // Pac-Man activates the instant it can't fall further ("hits the first
          // block") — no lock-delay, and no thud (the frenzy sting plays instead).
          const isPac = useDropBlockStore.getState().piece?.type === PACMAN;
          lockAccRef.current += dt;
          if (isPac || lockAccRef.current >= LOCK_DELAY) {
            useDropBlockStore.getState().lockPiece();
            if (!isPac) playLockSfx();
            lockAccRef.current = 0;
            acc = 0;
          }
        }
      } else {
        primed = false;            // re-sync the baseline when play resumes
        heldRef.current = {};      // drop held-key repeats while not playing
      }

      drawWell(clearAnim, blastAnim, fallAnim, pacAnim, now);
      const st2 = useDropBlockStore.getState();
      drawSide(holdRef.current, st2.hold);
      // A debug-armed power-up previews in the Next panel; random bombs stay a surprise.
      if (st2.pacArmed) drawSidePacman(nextRef.current, now);
      else if (st2.bombArmed) drawSideBomb(nextRef.current, now);
      else drawSide(nextRef.current, st2.queue[0]);
    };

    raf = requestAnimationFrame(frame);
    return () => { cancelled = true; cancelAnimationFrame(raf); };
  }, [status, resetLock, playLockSfx]);

  // ── Keyboard (capture phase so it preempts the inbox nav / shortcuts) ─────
  useEffect(() => {
    // Begin accelerating auto-repeat for a held movement key. The initial delay
    // shrinks at higher levels so movement keeps up with the faster fall.
    const startHold = (key) => {
      const das = repeatDelay(useDropBlockStore.getState().level);
      heldRef.current[key] = { nextAt: performance.now() + das, interval: das };
    };

    const onKeyDown = (e) => {
      // Never hijack browser/OS shortcuts (Ctrl+R, Cmd+C, …).
      if (e.ctrlKey || e.metaKey || e.altKey) return;

      // Yield to an open modal/dialog or a focused text field. This capture-phase
      // listener otherwise swallows their Enter/Escape — e.g. a confirm dialog's
      // autofocused primary button would start a game instead of confirming.
      if (document.querySelector('[data-overlay-open]')) return;
      const ae = document.activeElement;
      if (ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable)) return;

      const st = useDropBlockStore.getState();

      // Debug: `~` (or backtick) toggles debug mode; while on, `b` makes the next
      // piece a bomb. Hidden from the on-screen key hints on purpose.
      if (e.key === '~' || e.key === '`') {
        debugRef.current = !debugRef.current;
        setDebug(debugRef.current);
        e.preventDefault(); e.stopPropagation();
        return;
      }
      if (debugRef.current && (e.key === 'b' || e.key === 'B')) {
        if (st.status === STATUS.PLAYING) st.armBomb();
        e.preventDefault(); e.stopPropagation();
        return;
      }
      // While debugging, `p` makes the next piece a Pac-Man (so it pre-empts the
      // normal `p` = pause). Also hidden from the on-screen hints.
      if (debugRef.current && (e.key === 'p' || e.key === 'P')) {
        if (st.status === STATUS.PLAYING) st.armPacman();
        e.preventDefault(); e.stopPropagation();
        return;
      }

      // The game owns Space in every state — never let a (second) press scroll
      // the page or activate a focused app control, which looked like the inbox
      // "refreshing" back to the email view.
      if (e.key === ' ') {
        // No hard-drop during a Pac-Man frenzy (there's no falling piece then).
        if (st.status === STATUS.PLAYING && st.piece) {
          st.hardDrop();
          playLockSfx();
        }
        e.preventDefault(); e.stopPropagation();
        return;
      }

      if (st.status === STATUS.PLAYING) {
        // We run our own accelerating repeat, so swallow the OS key-repeat.
        if (e.repeat) { e.preventDefault(); e.stopPropagation(); return; }
        // During a Pac-Man frenzy the arrows steer the roamer (up/down/left/right);
        // everything else is ignored until the eating window ends.
        if (st.pac) {
          switch (e.key) {
            case 'ArrowLeft': st.pacSetDir('left'); break;
            case 'ArrowRight': st.pacSetDir('right'); break;
            case 'ArrowUp': st.pacSetDir('up'); break;
            case 'ArrowDown': st.pacSetDir('down'); break;
            default: return;
          }
          e.preventDefault(); e.stopPropagation();
          return;
        }
        switch (e.key) {
          case 'ArrowLeft': if (st.moveLeft()) { resetLock(); sfx('swoosh', 0.4); } startHold('ArrowLeft'); break;
          case 'ArrowRight': if (st.moveRight()) { resetLock(); sfx('swoosh', 0.4); } startHold('ArrowRight'); break;
          case 'ArrowUp':
          case 'x': case 'X': if (st.rotate(1)) { resetLock(); sfx('swoosh'); } break;
          case 'z': case 'Z': if (st.rotate(-1)) { resetLock(); sfx('swoosh'); } break;
          case 'ArrowDown': st.stepDown(true); startHold('ArrowDown'); break;
          // Enter holds the active piece (c / Shift also work).
          case 'Enter':
          case 'c': case 'C': case 'Shift': st.swapHold(); break;
          // R resets to a fresh game.
          case 'r': case 'R': st.restart(); break;
          // Escape only pauses — it never discards the game.
          case 'p': case 'P':
          case 'Escape': st.pause(); break;
          default: return;
        }
        e.preventDefault(); e.stopPropagation();
        return;
      }

      if (st.status === STATUS.PAUSED) {
        // Escape/Enter resume (a second Escape no longer wipes the board); R resets.
        if (e.key === 'Escape' || e.key === 'Enter' || e.key === ' ' || e.key === 'p' || e.key === 'P') st.resume();
        else if (e.key === 'r' || e.key === 'R') st.restart();
        else return;
        e.preventDefault(); e.stopPropagation();
        return;
      }

      if (st.status === STATUS.OVER) {
        if (e.key === 'Enter' || e.key === 'r' || e.key === 'R') st.restart();
        else if (e.key === 'Escape') st.exit();
        else return;
        e.preventDefault(); e.stopPropagation();
        return;
      }

      // IDLE — Enter launches a new game.
      if (e.key === 'Enter') {
        st.start();
        e.preventDefault(); e.stopPropagation();
      }
    };

    const onKeyUp = (e) => {
      if (e.key in REPEAT_KEYS) delete heldRef.current[e.key];
    };
    // If focus leaves the window mid-hold, the keyup may never arrive — drop all
    // held-key repeats so nothing keeps moving on its own.
    const clearHeld = () => { heldRef.current = {}; };

    window.addEventListener('keydown', onKeyDown, true);
    window.addEventListener('keyup', onKeyUp, true);
    window.addEventListener('blur', clearHeld);
    return () => {
      window.removeEventListener('keydown', onKeyDown, true);
      window.removeEventListener('keyup', onKeyUp, true);
      window.removeEventListener('blur', clearHeld);
    };
  }, [resetLock, playLockSfx]);

  // ── Touch controls (mobile) ───────────────────────────────────────────────
  // Tap zones on the well: left edge moves left, right edge moves right, the
  // centre rotates. Tap-and-hold soft-drops (faster fall) via the loop's
  // auto-repeat; a downward swipe hard-drops. During a Pac-Man frenzy, swipes
  // steer it (4-way) and the tap zones map to left / right / down.
  useEffect(() => {
    if (status === STATUS.IDLE) return;
    const el = wellRef.current;
    if (!el) return;

    const TAP_HOLD_MS = 170;            // press longer than this becomes a soft-drop hold
    const SWIPE_PX = 30;                // min travel for a swipe
    const LEFT_ZONE = 0.28, RIGHT_ZONE = 0.72;

    let sx = 0, sy = 0, startT = 0, acted = false, holding = false, holdTimer = 0, lastDir = null;
    const clearHoldTimer = () => { if (holdTimer) { clearTimeout(holdTimer); holdTimer = 0; } };
    const stopSoftDrop = () => { delete heldRef.current.ArrowDown; holding = false; };

    const onStart = (e) => {
      const t = e.changedTouches[0]; if (!t) return;
      e.preventDefault();
      if (useDropBlockStore.getState().status !== STATUS.PLAYING) return;
      sx = t.clientX; sy = t.clientY; startT = performance.now();
      acted = false; lastDir = null;
      // Hold to soft-drop — reuse the loop's ArrowDown auto-repeat. Not during a
      // frenzy (there's no falling piece then).
      if (!useDropBlockStore.getState().pac) {
        holdTimer = setTimeout(() => {
          holding = true;
          heldRef.current.ArrowDown = { nextAt: performance.now(), interval: repeatDelay(useDropBlockStore.getState().level) };
        }, TAP_HOLD_MS);
      }
    };

    const onMove = (e) => {
      const t = e.changedTouches[0]; if (!t) return;
      e.preventDefault();
      const dx = t.clientX - sx, dy = t.clientY - sy;
      const st = useDropBlockStore.getState();
      if (st.pac) {
        // Frenzy: swipe in the dominant direction to steer (re-arms each swipe).
        if (Math.max(Math.abs(dx), Math.abs(dy)) >= SWIPE_PX) {
          const dir = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'right' : 'left') : (dy > 0 ? 'down' : 'up');
          if (dir !== lastDir) { st.pacSetDir(dir); lastDir = dir; }
          sx = t.clientX; sy = t.clientY; acted = true; clearHoldTimer();
        }
        return;
      }
      // A downward swipe hard-drops.
      if (!acted && dy >= SWIPE_PX && dy > Math.abs(dx) * 1.2) {
        clearHoldTimer();
        if (holding) stopSoftDrop();
        if (st.piece) { st.hardDrop(); playLockSfx(); }
        acted = true;
      }
    };

    const onEnd = (e) => {
      e.preventDefault();
      clearHoldTimer();
      if (holding) { stopSoftDrop(); return; }
      if (acted) return;
      if (performance.now() - startT >= TAP_HOLD_MS) return; // long press, no action
      const st = useDropBlockStore.getState();
      if (st.status !== STATUS.PLAYING) return;
      const rect = el.getBoundingClientRect();
      const f = (sx - rect.left) / rect.width;
      if (st.pac) {
        st.pacSetDir(f < LEFT_ZONE ? 'left' : f > RIGHT_ZONE ? 'right' : 'down');
        return;
      }
      if (f < LEFT_ZONE) { if (st.moveLeft()) { resetLock(); sfx('swoosh', 0.4); } }
      else if (f > RIGHT_ZONE) { if (st.moveRight()) { resetLock(); sfx('swoosh', 0.4); } }
      else if (st.rotate(1)) { resetLock(); sfx('swoosh'); }
    };

    const onCancel = () => { clearHoldTimer(); if (holding) stopSoftDrop(); acted = true; };

    el.addEventListener('touchstart', onStart, { passive: false });
    el.addEventListener('touchmove', onMove, { passive: false });
    el.addEventListener('touchend', onEnd, { passive: false });
    el.addEventListener('touchcancel', onCancel, { passive: false });
    return () => {
      clearHoldTimer(); stopSoftDrop();
      el.removeEventListener('touchstart', onStart);
      el.removeEventListener('touchmove', onMove);
      el.removeEventListener('touchend', onEnd);
      el.removeEventListener('touchcancel', onCancel);
    };
  }, [status, resetLock, playLockSfx]);

  // Grab keyboard focus so input reaches the game. On a fresh page load the
  // document area may not hold focus yet (focus on browser chrome / a stale
  // field), so window keydown never fires until something here is focused.
  // We focus the playfield when it appears (unless the user is mid-typing) and
  // always when a game starts/resumes.
  useEffect(() => {
    const ae = document.activeElement;
    const inField = ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable);
    if (status === STATUS.PLAYING || !inField) {
      rootRef.current?.focus({ preventScroll: true });
    }
  }, [status]);

  // Leaving the empty pane (opening a conversation, switching folder/view) pauses
  // a running game instead of ending it, so returning to an empty pane resumes the
  // board where you left off. The paused state lives only in the in-memory store —
  // a full reload still starts fresh (only the best score is persisted).
  useEffect(() => () => {
    if (useDropBlockStore.getState().status === STATUS.PLAYING) {
      useDropBlockStore.getState().pause();
    }
  }, []);

  // Background music plays only while actively playing and unmuted.
  useEffect(() => {
    if (status === STATUS.PLAYING && !muted) startMusic();
    else stopMusic();
    return () => stopMusic();
  }, [status, muted]);

  // A Pac-Man frenzy races the music and fires a power-up sting on entry; tempo
  // returns to normal the moment it ends (or the game stops).
  useEffect(() => {
    if (pacActive && status === STATUS.PLAYING) {
      setMusicTempo(1.6);
      sfx('pacstart');
    } else {
      setMusicTempo(1);
    }
    return () => setMusicTempo(1);
  }, [pacActive, status]);

  // Desktop (Tauri) only: auto-pause when the app window loses focus and resume
  // when it comes back — but only if *we* paused it (a manual pause stays paused).
  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    let unlisten = null;
    let pausedByBlur = false;
    import('@tauri-apps/api/window').then(({ getCurrentWindow }) => {
      if (cancelled) return;
      getCurrentWindow().onFocusChanged(({ payload: focused }) => {
        const st = useDropBlockStore.getState();
        if (!focused) {
          if (st.status === STATUS.PLAYING) {
            st.pause();
            pausedByBlur = useDropBlockStore.getState().status === STATUS.PAUSED;
          }
        } else if (pausedByBlur) {
          if (useDropBlockStore.getState().status === STATUS.PAUSED) useDropBlockStore.getState().resume();
          pausedByBlur = false;
        }
      }).then((fn) => { if (cancelled) fn(); else unlisten = fn; });
    });
    return () => { cancelled = true; if (unlisten) unlisten(); };
  }, []);

  // Sad descending sting the moment we top out (transition into OVER only).
  const prevStatus = useRef(status);
  useEffect(() => {
    if (status === STATUS.OVER && prevStatus.current !== STATUS.OVER) sfx('gameover');
    prevStatus.current = status;
  }, [status]);

  // Preload the burst stickers so the first clear shows them instantly.
  useEffect(() => {
    [...SMALL_BURSTS, BIG_BURST].forEach((k) => { const img = new Image(); img.src = asset(`/dropblock/${k}.png`); });
  }, []);

  // Fire a burst the moment a line-clear begins: the big BAM for a four-line
  // clear, otherwise a random pop-art word. `clearing` flips back to null when
  // the animation commits. As the level (and fall speed) climbs the burst gets
  // quicker and more see-through so it flashes by without obscuring the board.
  useEffect(() => {
    if (!clearing || !clearing.rows?.length) return;
    const lvl = useDropBlockStore.getState().level;
    const speed = Math.max(0.4, 1 - (lvl - 1) * 0.08);   // duration shrinks with level
    const isBig = clearing.rows.length >= 4;
    const kind = isBig ? BIG_BURST : SMALL_BURSTS[Math.floor(Math.random() * SMALL_BURSTS.length)];
    // Anchor the burst two rows above the last (lowest) cleared row. The well fills
    // its box at exactly COLS×ROWS, so a row maps linearly to a vertical %. When the
    // clear is in the top few rows there's no room above it, so float the burst just
    // above the playing area instead. `top` is the centre point (the img is centred
    // on it via translate(-50%, -50%)).
    const lastRow = Math.max(...clearing.rows);
    const ABOVE_PLAYFIELD = -7; // % — sits above the well's top edge (top-rows case)
    const top = lastRow <= TOP_ROWS_LIMIT
      ? ABOVE_PLAYFIELD
      : ((lastRow - 2 + 0.5) / ROWS) * 100;
    burstSeq.current += 1;
    setBurst({
      kind,
      tier: isBig ? 'big' : 'small',
      key: burstSeq.current,
      dur: Math.round((isBig ? 900 : 720) * speed),
      peak: Math.max(0.6, 1 - (lvl - 1) * 0.045),         // a touch more transparent at speed
      top,
    });
  }, [clearing]);

  // A single focusable region wraps both the idle hint and the running game so
  // the keyboard always has a reliable focus target (click anywhere refocuses).
  const focusSelf = () => rootRef.current?.focus({ preventScroll: true });

  // On-screen touch d-pad (mobile). Reuses the loop's held-key auto-repeat for
  // press-and-hold on ←/→/↓; rotate is a single tap. Frenzy-aware.
  const PAD_KEY = { left: 'ArrowLeft', right: 'ArrowRight', down: 'ArrowDown' };
  const padAct = (dir) => {
    const s = useDropBlockStore.getState();
    if (s.status !== STATUS.PLAYING) return;
    if (s.pac) { if (dir !== 'rotate') s.pacSetDir(dir); return; }
    if (dir === 'left') { if (s.moveLeft()) { resetLock(); sfx('swoosh', 0.4); } }
    else if (dir === 'right') { if (s.moveRight()) { resetLock(); sfx('swoosh', 0.4); } }
    else if (dir === 'down') { s.stepDown(true); }
    else if (dir === 'rotate') { if (s.rotate(1)) { resetLock(); sfx('swoosh'); } }
  };
  const padDown = (dir) => (e) => {
    e.preventDefault();
    padAct(dir);
    const key = PAD_KEY[dir];
    if (key) {
      const das = repeatDelay(useDropBlockStore.getState().level);
      heldRef.current[key] = { nextAt: performance.now() + das, interval: das };
    }
  };
  const padUp = (dir) => () => { const key = PAD_KEY[dir]; if (key) delete heldRef.current[key]; };
  const padBtn = (dir, glyph, label) => (
    <button
      type="button" tabIndex={-1} aria-label={label} className={styles.padBtn}
      onPointerDown={padDown(dir)}
      onPointerUp={PAD_KEY[dir] ? padUp(dir) : undefined}
      onPointerLeave={PAD_KEY[dir] ? padUp(dir) : undefined}
      onPointerCancel={PAD_KEY[dir] ? padUp(dir) : undefined}
    >{glyph}</button>
  );

  // ── Idle: the normal zero-state, with a play hint ─────────────────────────
  if (status === STATUS.IDLE) {
    return (
      <div ref={rootRef} className={styles.focusRoot} tabIndex={0} role="application" aria-label="DropBlock" onMouseDown={focusSelf}>
        <div className={styles.idle}>
          <img src={iconSrc || logoSrc} alt="" className={styles.idleLogo} />
          <div className={styles.idleText}>Select a conversation to view</div>
          <button type="button" className={styles.playHint} onClick={() => useDropBlockStore.getState().start()}>
            Press <kbd>⏎</kbd> to play DropBlock
          </button>
        </div>
      </div>
    );
  }

  // ── Game ──────────────────────────────────────────────────────────────────
  return (
    <div ref={rootRef} className={`${styles.focusRoot} ${styles.root}`} tabIndex={0} role="application" aria-label="DropBlock" onMouseDown={focusSelf}>
      <div className={styles.stage}>
        <aside className={`${styles.side} ${styles.sideLeft}`}>
          <div className={styles.panel}>
            <div className={styles.panelLabel}>Hold</div>
            <canvas ref={holdRef} className={styles.mini} />
          </div>
          <div className={styles.panel}>
            <div className={styles.stats}>
              <div className={styles.stat}>
                <div className={styles.statLabel}>Score</div>
                <div className={styles.statValue}>{score.toLocaleString()}</div>
              </div>
              <div className={styles.stat}>
                <div className={styles.statLabel}>Best</div>
                <div className={styles.statValue}>{Math.max(best, score).toLocaleString()}</div>
              </div>
              <div className={styles.stat}>
                <div className={styles.statLabel}>Level</div>
                <div className={styles.statValue}>{level}</div>
              </div>
              <div className={styles.stat}>
                <div className={styles.statLabel}>Lines</div>
                <div className={styles.statValue}>{lines}</div>
              </div>
            </div>
            {beat && <div className={styles.newBest}>★ New best!</div>}
          </div>
        </aside>

        <div className={styles.wellWrap}>
        <div className={styles.well}>
          <canvas ref={wellRef} className={styles.wellCanvas} />

          <button
            type="button"
            className={styles.soundToggle}
            onClick={toggleMute}
            title={muted ? 'Unmute music & sound' : 'Mute'}
            aria-label={muted ? 'Unmute' : 'Mute'}
            data-on={!muted}
          >
            <SpeakerIcon muted={muted} />
          </button>

          {status === STATUS.PAUSED && (
            <div className={styles.overlay}>
              <div className={styles.overlayTitle}>Paused</div>
              <div className={styles.overlayHint}>
                <button type="button" className={styles.btn} onClick={() => useDropBlockStore.getState().resume()}>Resume</button>
                <button type="button" className={styles.btnGhost} onClick={() => useDropBlockStore.getState().restart()}>Reset</button>
              </div>
              <div className={styles.overlaySub}><kbd>Esc</kbd> resume · <kbd>R</kbd> reset</div>
            </div>
          )}

          {status === STATUS.OVER && (
            <div className={styles.overlay}>
              <div className={`${styles.overlayTitle} ${styles.shimmerText}`}>
                {beat ? 'New high score!' : 'Game over'}
              </div>
              <div className={styles.overlayScore}>{score.toLocaleString()}</div>
              {best > score && <div className={styles.overlayBest}>Best {best.toLocaleString()}</div>}
              <div className={styles.overlayHint}>
                <button type="button" className={styles.btn} onClick={() => useDropBlockStore.getState().restart()}>Play again</button>
                <button type="button" className={styles.btnGhost} onClick={() => useDropBlockStore.getState().exit()}>Exit</button>
              </div>
              <div className={styles.overlaySub}><kbd>⏎</kbd> / <kbd>R</kbd> play again · <kbd>Esc</kbd> exit</div>
            </div>
          )}
        </div>

        {/* Burst lives outside the (clipped) well so it can float above the play area. */}
        {burst && (
          <img
            key={burst.key}
            ref={(el) => {
              if (!el) return;
              el.style.setProperty('--burst-dur', `${burst.dur}ms`);
              el.style.setProperty('--burst-peak', `${burst.peak}`);
              el.style.setProperty('--burst-top', `${burst.top}%`);
            }}
            src={asset(`/dropblock/${burst.kind}.png`)}
            className={`${styles.burst} ${styles[burst.tier]}`}
            alt=""
            aria-hidden="true"
            onAnimationEnd={() => setBurst(null)}
          />
        )}
        </div>

        <aside className={`${styles.side} ${styles.sideRight}`}>
          <div className={styles.panel}>
            <div className={styles.panelLabel}>Next</div>
            <canvas ref={nextRef} className={styles.mini} />
          </div>
          <div className={styles.controls}>
            <div className={styles.controlsRow}><kbd>←</kbd><kbd>→</kbd> move</div>
            <div className={styles.controlsRow}><kbd>↑</kbd> rotate</div>
            <div className={styles.controlsRow}><kbd>↓</kbd> soft drop</div>
            <div className={styles.controlsRow}><kbd>space</kbd> hard drop</div>
            <div className={styles.controlsRow}><kbd>⏎</kbd> hold</div>
            <div className={styles.controlsRow}><kbd>R</kbd> reset</div>
            <div className={styles.controlsRow}><kbd>Esc</kbd> pause</div>
          </div>
          {debug && <div className={styles.debugChip}>DEBUG · <kbd>B</kbd> bomb · <kbd>P</kbd> pac</div>}
        </aside>

        {/* On-screen d-pad — shown only on the narrow (touch) layout. */}
        <div className={styles.touchpad}>
          {padBtn('rotate', '↻', 'Rotate')}
          {padBtn('left', '◀', 'Move left')}
          {padBtn('down', '▼', 'Soft drop')}
          {padBtn('right', '▶', 'Move right')}
        </div>
      </div>
    </div>
  );
}
