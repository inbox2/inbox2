// ── DropBlock engine ─────────────────────────────────────────────────────────
// Pure, framework-free falling-block game logic following the well-known
// guideline ruleset: a 10×20 well, the Super Rotation System with wall kicks, a
// 7-bag randomiser, hold, ghost piece, an accelerating gravity curve and
// scoring. The store and the React component import these helpers; nothing here
// touches the DOM, React or timers.

export const COLS = 10;
export const ROWS = 20;

// Block keys. Defined once and reused everywhere (no raw strings floating
// around the store/component) per the project's "no duplicated enums" rule.
export const PIECE = {
  I: 'I', O: 'O', T: 'T', S: 'S', Z: 'Z', J: 'J', L: 'L',
};
export const PIECE_TYPES = [PIECE.I, PIECE.O, PIECE.T, PIECE.S, PIECE.Z, PIECE.J, PIECE.L];

// Special single-cell power-up that drops in at random (never part of the 7-bag).
// On lock it detonates in a cross, vaporizing its whole row and column instead of
// settling as a block. The store schedules it; the component renders the sprite.
export const BOMB = 'BOMB';

// Special single-cell power-up (debug-only spawn, via `p`). It falls eating
// downward; the moment it can't fall any further (hits the first block or the
// floor) it activates into a timed "eating frenzy": it flashes, the music speeds
// up, and the player steers it up/down/left/right to chomp every block it touches
// for a few seconds. Never settles as a block. The store models the frenzy; the
// component renders the animated Pac-Man sprite and drives the timer.
export const PACMAN = 'PACMAN';

// Standard guideline block colours.
export const COLORS = {
  [PIECE.I]: '#31c7ef',
  [PIECE.O]: '#f7d308',
  [PIECE.T]: '#ad4d9c',
  [PIECE.S]: '#42b642',
  [PIECE.Z]: '#ef2029',
  [PIECE.J]: '#5a65ad',
  [PIECE.L]: '#ef7921',
  [BOMB]: '#0b0f1a', // fallback only — the bomb is drawn from a sprite, never as a block
  [PACMAN]: '#ffe24a', // fallback only — Pac-Man is drawn from sprite frames, never as a block
};

// Rotation states (0=spawn, 1=CW, 2=180, 3=CCW) as solid/empty matrices.
// J/L/S/T/Z live in a 3×3 box, I in a 4×4 box, O in a 2×2 box. These are the
// canonical SRS shapes.
export const SHAPES = {
  [PIECE.I]: [
    [[0,0,0,0],[1,1,1,1],[0,0,0,0],[0,0,0,0]],
    [[0,0,1,0],[0,0,1,0],[0,0,1,0],[0,0,1,0]],
    [[0,0,0,0],[0,0,0,0],[1,1,1,1],[0,0,0,0]],
    [[0,1,0,0],[0,1,0,0],[0,1,0,0],[0,1,0,0]],
  ],
  [PIECE.O]: [
    [[1,1],[1,1]],
    [[1,1],[1,1]],
    [[1,1],[1,1]],
    [[1,1],[1,1]],
  ],
  [PIECE.T]: [
    [[0,1,0],[1,1,1],[0,0,0]],
    [[0,1,0],[0,1,1],[0,1,0]],
    [[0,0,0],[1,1,1],[0,1,0]],
    [[0,1,0],[1,1,0],[0,1,0]],
  ],
  [PIECE.S]: [
    [[0,1,1],[1,1,0],[0,0,0]],
    [[0,1,0],[0,1,1],[0,0,1]],
    [[0,0,0],[0,1,1],[1,1,0]],
    [[1,0,0],[1,1,0],[0,1,0]],
  ],
  [PIECE.Z]: [
    [[1,1,0],[0,1,1],[0,0,0]],
    [[0,0,1],[0,1,1],[0,1,0]],
    [[0,0,0],[1,1,0],[0,1,1]],
    [[0,1,0],[1,1,0],[1,0,0]],
  ],
  [PIECE.J]: [
    [[1,0,0],[1,1,1],[0,0,0]],
    [[0,1,1],[0,1,0],[0,1,0]],
    [[0,0,0],[1,1,1],[0,0,1]],
    [[0,1,0],[0,1,0],[1,1,0]],
  ],
  [PIECE.L]: [
    [[0,0,1],[1,1,1],[0,0,0]],
    [[0,1,0],[0,1,0],[0,1,1]],
    [[0,0,0],[1,1,1],[1,0,0]],
    [[1,1,0],[0,1,0],[0,1,0]],
  ],
  // The bomb is a single cell in every rotation state (it never rotates).
  [BOMB]: [[[1]], [[1]], [[1]], [[1]]],
  // Pac-Man is likewise a single cell in every rotation state (never rotates).
  [PACMAN]: [[[1]], [[1]], [[1]], [[1]]],
};

// SRS wall-kick offsets. Source tables are written with y pointing up; the well
// has y pointing down, so the y component is negated here. Keyed by
// "from>>to" rotation index.
const KICKS_JLSTZ = {
  '0>>1': [[0,0],[-1,0],[-1,-1],[0,2],[-1,2]],
  '1>>0': [[0,0],[1,0],[1,1],[0,-2],[1,-2]],
  '1>>2': [[0,0],[1,0],[1,1],[0,-2],[1,-2]],
  '2>>1': [[0,0],[-1,0],[-1,-1],[0,2],[-1,2]],
  '2>>3': [[0,0],[1,0],[1,-1],[0,2],[1,2]],
  '3>>2': [[0,0],[-1,0],[-1,1],[0,-2],[-1,-2]],
  '3>>0': [[0,0],[-1,0],[-1,1],[0,-2],[-1,-2]],
  '0>>3': [[0,0],[1,0],[1,-1],[0,2],[1,2]],
};
const KICKS_I = {
  '0>>1': [[0,0],[-2,0],[1,0],[-2,1],[1,-2]],
  '1>>0': [[0,0],[2,0],[-1,0],[2,-1],[-1,2]],
  '1>>2': [[0,0],[-1,0],[2,0],[-1,-2],[2,1]],
  '2>>1': [[0,0],[1,0],[-2,0],[1,2],[-2,-1]],
  '2>>3': [[0,0],[2,0],[-1,0],[2,-1],[-1,2]],
  '3>>2': [[0,0],[-2,0],[1,0],[-2,1],[1,-2]],
  '3>>0': [[0,0],[1,0],[-2,0],[1,2],[-2,-1]],
  '0>>3': [[0,0],[-1,0],[2,0],[-1,-2],[2,1]],
};

export function emptyBoard() {
  return Array.from({ length: ROWS }, () => Array(COLS).fill(null));
}

// Fisher–Yates shuffle of one 7-bag.
function shuffledBag() {
  const bag = [...PIECE_TYPES];
  for (let i = bag.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [bag[i], bag[j]] = [bag[j], bag[i]];
  }
  return bag;
}

// Keep the upcoming-queue topped up so we can always preview the next pieces.
// Returns a *new* queue array (never mutates the input).
export function refillQueue(queue) {
  const next = [...queue];
  while (next.length <= PIECE_TYPES.length) next.push(...shuffledBag());
  return next;
}

// Spawn coordinates place the piece centred at the top of the well, matching
// the guideline (columns 3–6).
export function spawnPiece(type) {
  if (type === BOMB || type === PACMAN) return { type, rot: 0, x: 4, y: 0 }; // single cell, centred
  const x = type === PIECE.O ? 4 : 3;
  return { type, rot: 0, x, y: 0 };
}

// Absolute well cells [{x,y}] occupied by a piece in its current rotation.
export function pieceCells(piece) {
  const shape = SHAPES[piece.type][piece.rot];
  const cells = [];
  for (let r = 0; r < shape.length; r++) {
    for (let c = 0; c < shape[r].length; c++) {
      if (shape[r][c]) cells.push({ x: piece.x + c, y: piece.y + r });
    }
  }
  return cells;
}

// A placement is valid when every cell is inside the side/bottom walls and not
// overlapping a settled block. Cells above the top (y<0) are allowed so pieces
// can spawn/rotate partly off the top edge.
export function isValid(board, piece) {
  for (const { x, y } of pieceCells(piece)) {
    if (x < 0 || x >= COLS || y >= ROWS) return false;
    if (y >= 0 && board[y][x]) return false;
  }
  return true;
}

// Attempt an SRS rotation by `dir` (+1 CW, -1 CCW), walking the kick table.
// Returns the rotated+kicked piece, or null if every kick is blocked.
export function tryRotate(board, piece, dir) {
  if (piece.type === PIECE.O || piece.type === BOMB || piece.type === PACMAN) return null; // O / bomb / Pac-Man never rotate
  const from = piece.rot;
  const to = (from + dir + 4) % 4;
  const table = piece.type === PIECE.I ? KICKS_I : KICKS_JLSTZ;
  const tests = table[`${from}>>${to}`] || [[0, 0]];
  for (const [dx, dy] of tests) {
    const candidate = { ...piece, rot: to, x: piece.x + dx, y: piece.y + dy };
    if (isValid(board, candidate)) return candidate;
  }
  return null;
}

// Drop the piece straight down to its resting row (used for the ghost and for
// hard drop). Returns the landed copy.
export function dropToFloor(board, piece) {
  let p = piece;
  while (isValid(board, { ...p, y: p.y + 1 })) p = { ...p, y: p.y + 1 };
  return p;
}

// Merge a piece into the board (returns a new board) — used on lock.
export function mergePiece(board, piece) {
  const next = board.map((row) => [...row]);
  for (const { x, y } of pieceCells(piece)) {
    if (y >= 0 && y < ROWS && x >= 0 && x < COLS) next[y][x] = piece.type;
  }
  return next;
}

// Per-column gravity: compact every column to the bottom so blocks left floating
// after cells are vaporized (bomb cross, Pac-Man chomps) fall in to fill the
// gaps. Returns a new settled board plus a `fall` list of the blocks that moved
// ({ x, from, to, type }) so the component can animate the drop. Pure.
export function collapseColumns(board) {
  const next = emptyBoard();
  const fall = [];
  for (let c = 0; c < COLS; c++) {
    const stack = [];
    for (let r = 0; r < ROWS; r++) if (board[r][c]) stack.push({ from: r, type: board[r][c] });
    const base = ROWS - stack.length;
    for (let i = 0; i < stack.length; i++) {
      const to = base + i;
      next[to][c] = stack[i].type;
      if (to !== stack[i].from) fall.push({ x: c, from: stack[i].from, to, type: stack[i].type });
    }
  }
  return { board: next, fall };
}

// Remove full rows. Returns { board, cleared }.
export function clearLines(board) {
  const kept = board.filter((row) => row.some((cell) => !cell));
  const cleared = ROWS - kept.length;
  while (kept.length < ROWS) kept.unshift(Array(COLS).fill(null));
  return { board: kept, cleared };
}

// Level → gravity in milliseconds per row. Guideline curve:
//   time = (0.8 − (level−1)·0.007) ^ (level−1) seconds
// Level 1 ≈ 1000ms, ramping toward ~instant by level ~20. This is what gives
// the game its accelerating pace.
export function gravityMs(level) {
  const t = Math.pow(0.8 - (level - 1) * 0.007, level - 1);
  return Math.max(t * 1000, 16);
}

// Guideline line-clear scores (before the level multiplier).
const LINE_SCORES = { 1: 100, 2: 300, 3: 500, 4: 800 };
export function lineScore(cleared, level) {
  return (LINE_SCORES[cleared] || 0) * level;
}

export function levelForLines(lines) {
  return Math.floor(lines / 10) + 1;
}
