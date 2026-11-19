import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';
import {
  ROWS, COLS, BOMB, PACMAN, emptyBoard, refillQueue, spawnPiece, pieceCells, isValid, tryRotate,
  dropToFloor, mergePiece, collapseColumns, lineScore, levelForLines,
} from '../components/DropBlock/engine';
import { DROPBLOCK_STATE } from '../lib/storageKeys';

// localStorage that can't throw. Some embedded WebViews (iOS `loadHTMLString`
// with an opaque origin) raise a SecurityError on *any* localStorage access; an
// unguarded persist read at store creation would crash the whole bundle (blank
// game). Probe once and fall back to an in-memory map when it's unavailable.
const memoryStore = new Map();
const memoryStorage = {
  getItem: (k) => (memoryStore.has(k) ? memoryStore.get(k) : null),
  setItem: (k, v) => { memoryStore.set(k, String(v)); },
  removeItem: (k) => { memoryStore.delete(k); },
};
function safeStorage() {
  try {
    const probe = '__dropblock_probe__';
    window.localStorage.setItem(probe, '1');
    window.localStorage.removeItem(probe);
    return window.localStorage;
  } catch {
    return memoryStorage;
  }
}

// Game status. Persisted in the store so a game survives the empty-state
// component unmounting (e.g. when a conversation is opened) — that's how Escape
// "stops but remembers the state": we move to PAUSED and keep the board.
export const STATUS = {
  IDLE: 'idle',     // no game in progress — the normal zero-state is shown
  PLAYING: 'playing',
  PAUSED: 'paused', // frozen, board retained, resumable
  OVER: 'over',     // topped out — restart or exit
};

const SOFT_DROP_POINTS = 1; // per cell, while soft-dropping
const HARD_DROP_POINTS = 2; // per cell
const PAC_EAT_POINTS = 15;  // per block chomped during a Pac-Man frenzy

// Fold a new score into the state: bump the all-time best, and raise the
// one-time `beat` flag the moment this game passes the best it started under.
function scorePatch(state, newScore) {
  const patch = { score: newScore };
  if (newScore > state.best) patch.best = newScore;
  if (!state.beat && state.prevBest > 0 && newScore > state.prevBest) patch.beat = true;
  return patch;
}

// Pieces between random bombs — long enough that a bomb stays a treat, not a
// constant. Re-rolled each time a bomb spawns.
function randBombGap() { return 22 + Math.floor(Math.random() * 17); } // 22–38
// Pieces between random Pac-Men — about twice the bomb gap, so the stronger
// power-up stays a rarer treat. Re-rolled each time a Pac-Man spawns.
function randPacGap() { return 45 + Math.floor(Math.random() * 36); } // 45–80

// Pull the next active piece from the stream. Order: debug-armed pieces win
// first (`p` Pac-Man, then `b` bomb); then the random power-ups when their
// countdown elapses — the rarer Pac-Man checked before the bomb; otherwise the
// next 7-bag piece. Special pieces don't consume the queue and only the normal
// pull ticks the countdowns down.
function takeNext(state) {
  if (state.pacArmed) {
    return { piece: spawnPiece(PACMAN), queue: state.queue, bombIn: state.bombIn, pacIn: state.pacIn, bombArmed: state.bombArmed, pacArmed: false };
  }
  if (state.bombArmed) {
    return { piece: spawnPiece(BOMB), queue: state.queue, bombIn: randBombGap(), pacIn: state.pacIn, bombArmed: false, pacArmed: false };
  }
  if (state.pacIn <= 0) {
    return { piece: spawnPiece(PACMAN), queue: state.queue, bombIn: state.bombIn, pacIn: randPacGap(), bombArmed: false, pacArmed: false };
  }
  if (state.bombIn <= 0) {
    return { piece: spawnPiece(BOMB), queue: state.queue, bombIn: randBombGap(), pacIn: state.pacIn, bombArmed: false, pacArmed: false };
  }
  const queue = refillQueue([...state.queue]);
  const type = queue.shift();
  return { piece: spawnPiece(type), queue, bombIn: state.bombIn - 1, pacIn: state.pacIn - 1, bombArmed: false, pacArmed: false };
}

// Build a fresh game state object (board, queue, first piece).
function newGame() {
  const queue = refillQueue([]);
  const type = queue.shift();
  return {
    board: emptyBoard(),
    piece: spawnPiece(type),
    queue,
    hold: null,
    canHold: true,
    score: 0,
    lines: 0,
    level: 1,
    // While non-null ({ rows: number[] }) a line-clear animation is playing:
    // the full rows are still on the board (so they can flash) and there is no
    // active piece until finishClear() collapses them.
    clearing: null,
    // While non-null ({ col, row }) a bomb detonation animation is playing; the
    // component drives the beams and calls collapseBomb() to clear the cross.
    blast: null,
    // While non-null (an array of { x, from, to, type }) the post-blast gravity
    // collapse is animating; the component drives the drop and calls finishFall().
    fall: null,
    // While non-null ({ x, y, dir }) a Pac-Man eating frenzy is live: the piece
    // has activated and is roaming the well chomping blocks. The component drives
    // the move cadence + countdown and calls finishPac() when time runs out.
    pac: null,
    // True while a power-up (bomb/Pac-Man) has fully resolved and we're holding a
    // short beat (the settled board on show) before the next piece spawns. The
    // component times the hold and calls spawnNext().
    pendingSpawn: false,
    bombIn: randBombGap(), // pieces until the next random bomb
    pacIn: randPacGap(),   // pieces until the next random Pac-Man
    bombArmed: false,      // debug: force the next piece to be a bomb
    pacArmed: false,       // debug (`p`): force the next piece to be a Pac-Man
  };
}

const useDropBlockStore = create(persist((set, get) => ({
  status: STATUS.IDLE,
  best: 0,      // all-time high score (persisted)
  prevBest: 0,  // best at the start of the current game — the bar to beat
  beat: false,  // true once this game's score passes prevBest (drives the flourish)
  ...newGame(),

  // ── Lifecycle ──────────────────────────────────────────────────────────
  // A new game records the current best as the bar to beat and clears the flag.
  start() { set({ status: STATUS.PLAYING, ...newGame(), prevBest: get().best || 0, beat: false }); },
  restart() { get().start(); },
  resume() { if (get().status === STATUS.PAUSED) set({ status: STATUS.PLAYING }); },
  // Don't pause mid-animation (a line clear or bomb blast) — it would freeze the
  // canvas loop with the commit pending. The animation is ~400ms; pause after.
  pause() { const s = get(); if (s.status === STATUS.PLAYING && !s.clearing && !s.blast && !s.fall && !s.pac && !s.pendingSpawn) set({ status: STATUS.PAUSED }); },
  // Fully leave the game and return to the normal empty state. Clears the board
  // (but keeps the all-time best) so the next launch starts fresh.
  exit() { set({ status: STATUS.IDLE, ...newGame(), beat: false }); },

  // ── Movement ───────────────────────────────────────────────────────────
  // Each returns true when it changed the piece, so the component can reset its
  // lock-delay timer on a successful move/rotate.
  moveLeft() { return get()._shift(-1); },
  moveRight() { return get()._shift(1); },
  _shift(dx) {
    const { board, piece, status, clearing } = get();
    if (status !== STATUS.PLAYING || clearing || !piece) return false;
    const moved = { ...piece, x: piece.x + dx };
    if (isValid(board, moved)) { set({ piece: moved }); return true; }
    return false;
  },

  rotate(dir) {
    const { board, piece, status, clearing } = get();
    if (status !== STATUS.PLAYING || clearing || !piece) return false;
    const next = tryRotate(board, piece, dir);
    if (next) { set({ piece: next }); return true; }
    return false;
  },

  // True if the piece can still fall one row (used for lock-delay detection).
  canMoveDown() {
    const { board, piece, clearing } = get();
    if (clearing || !piece) return false;
    return isValid(board, { ...piece, y: piece.y + 1 });
  },

  // Gravity / soft-drop step. `soft` adds the soft-drop point. Returns true if
  // the piece descended a row.
  stepDown(soft = false) {
    const { board, piece, status, score, clearing } = get();
    if (status !== STATUS.PLAYING || clearing || !piece) return false;
    const moved = { ...piece, y: piece.y + 1 };
    if (isValid(board, moved)) {
      if (soft) set({ piece: moved, ...scorePatch(get(), score + SOFT_DROP_POINTS) });
      else set({ piece: moved });
      return true;
    }
    return false;
  },

  hardDrop() {
    const { board, piece, status, score, clearing } = get();
    if (status !== STATUS.PLAYING || clearing || !piece) return;
    const landed = dropToFloor(board, piece);
    const dist = landed.y - piece.y;
    set({ piece: landed, ...scorePatch(get(), score + dist * HARD_DROP_POINTS) });
    get().lockPiece();
  },

  // Swap the active piece with the hold slot (once per piece — the guideline
  // rule that prevents infinite stalling). Named swapHold (not hold) to avoid
  // clobbering the `hold` state field on reset.
  swapHold() {
    const { piece, hold, queue, canHold, status, board, clearing, blast } = get();
    if (status !== STATUS.PLAYING || clearing || blast || !piece || !canHold) return;
    if (piece.type === BOMB || piece.type === PACMAN) return; // power-ups can't be banked

    const heldType = piece.type;
    let nextQueue = queue;
    let nextPiece;
    if (hold) {
      nextPiece = spawnPiece(hold);
    } else {
      nextQueue = refillQueue([...queue]);
      nextPiece = spawnPiece(nextQueue.shift());
    }
    // If the swapped-in piece can't even spawn, it's a top-out.
    if (!isValid(board, nextPiece)) {
      set({ hold: heldType, canHold: false, status: STATUS.OVER });
      return;
    }
    set({ piece: nextPiece, hold: heldType, queue: nextQueue, canHold: false });
  },

  // Settle the current piece into the board. If it completes any rows, enter the
  // line-clear animation (the rows stay on the board so they can flash) and let
  // the component call finishClear() when the animation ends. Otherwise spawn
  // the next piece immediately (or top out).
  lockPiece() {
    const state = get();
    if (state.status !== STATUS.PLAYING || state.clearing || state.blast || !state.piece) return;

    // A bomb never settles as a block — it detonates in a cross at its resting
    // cell. Hold the origin and let the component animate; finishBlast() commits.
    if (state.piece.type === BOMB) {
      set({ piece: null, blast: { col: state.piece.x, row: state.piece.y } });
      return;
    }

    // Pac-Man never settles either — the moment it can't fall any further (it's
    // "hit the first block") it activates into a roaming eating frenzy at its
    // resting cell, facing down (so it immediately chomps the block beneath it).
    // The component drives the move cadence + countdown and calls finishPac().
    if (state.piece.type === PACMAN) {
      set({ piece: null, pac: { x: state.piece.x, y: state.piece.y, dir: 'down' } });
      return;
    }

    const merged = mergePiece(state.board, state.piece);

    const fullRows = [];
    for (let r = 0; r < ROWS; r++) {
      if (merged[r].every((c) => c)) fullRows.push(r);
    }

    if (fullRows.length > 0) {
      // Hold the merged board (rows still present) and animate; no active piece.
      set({ board: merged, piece: null, clearing: { rows: fullRows } });
      return;
    }

    const nx = takeNext(state);
    if (!isValid(merged, nx.piece)) {
      set({ board: merged, piece: null, status: STATUS.OVER });
      return;
    }
    set({ board: merged, queue: nx.queue, bombIn: nx.bombIn, pacIn: nx.pacIn, bombArmed: nx.bombArmed, pacArmed: nx.pacArmed, piece: nx.piece, canHold: true });
  },

  // Commit a finished line-clear animation: drop the rows above into the gaps,
  // award the score, level up, and spawn the next piece (or top out).
  finishClear() {
    const state = get();
    if (!state.clearing) return;
    const cleared = state.clearing.rows;
    const clearedSet = new Set(cleared);

    const kept = state.board.filter((_, r) => !clearedSet.has(r));
    while (kept.length < ROWS) kept.unshift(Array(COLS).fill(null));

    const lines = state.lines + cleared.length;
    const level = levelForLines(lines);
    const sp = scorePatch(state, state.score + lineScore(cleared.length, state.level));

    const nx = takeNext(state);
    if (!isValid(kept, nx.piece)) {
      set({ board: kept, lines, level, ...sp, clearing: null, piece: null, status: STATUS.OVER });
      return;
    }
    set({ board: kept, lines, level, ...sp, clearing: null, queue: nx.queue, bombIn: nx.bombIn, pacIn: nx.pacIn, bombArmed: nx.bombArmed, pacArmed: nx.pacArmed, piece: nx.piece, canHold: true });
  },

  // End of the beam animation: vaporize every settled block in the bomb's row
  // and column, award a bonus (per block × level), then let each column collapse
  // to the bottom so the blocks above fall in to fill the cleared cells. Moved
  // blocks are recorded in `fall` for the component to animate; finishFall()
  // commits and spawns the next piece. If nothing moved, spawn immediately.
  collapseBomb() {
    const state = get();
    if (!state.blast) return;
    const { col, row } = state.blast;
    const punched = state.board.map((r) => [...r]);
    let cleared = 0;
    for (let r = 0; r < ROWS; r++) if (punched[r][col]) { punched[r][col] = null; cleared += 1; }
    for (let c = 0; c < COLS; c++) if (punched[row][c]) { punched[row][c] = null; cleared += 1; }

    // Per-column gravity: surviving blocks fall to fill the cleared cells.
    const { board, fall } = collapseColumns(punched);

    const sp = scorePatch(state, state.score + cleared * 30 * state.level);
    if (fall.length === 0) {
      // Nothing to settle — hold a short beat, then spawn (spawnNext).
      set({ board, blast: null, fall: null, pendingSpawn: true, ...sp });
      return;
    }
    // Board is already settled; the component animates `fall`, then finishFall().
    set({ board, blast: null, fall, ...sp });
  },

  // Commit a finished bomb/Pac-Man collapse. The blocks that fell in to fill the
  // vaporized cells may themselves complete one or more rows — clear those first
  // (reusing the line-clear animation, which awards the score and spawns next).
  // Otherwise hold a short beat on the settled board, then spawn (spawnNext).
  finishFall() {
    const state = get();
    if (!state.fall) return;
    const fullRows = [];
    for (let r = 0; r < ROWS; r++) {
      if (state.board[r].every((c) => c)) fullRows.push(r);
    }
    if (fullRows.length > 0) {
      set({ fall: null, clearing: { rows: fullRows } });
      return;
    }
    set({ fall: null, pendingSpawn: true });
  },

  // ── Pac-Man eating frenzy ────────────────────────────────────────────────
  // Steer the roaming Pac-Man. Only the direction is set here; the component's
  // move cadence advances it cell-by-cell via pacStep().
  pacSetDir(dir) {
    const { pac, status } = get();
    if (status !== STATUS.PLAYING || !pac) return;
    if (pac.dir !== dir) set({ pac: { ...pac, dir } });
  },

  // Advance the roaming Pac-Man one cell in its current direction, chomping the
  // block in the destination cell (if any) for points. Stops at the walls/floor
  // (the player redirects). Returns true if it actually ate a block this step.
  pacStep() {
    const { pac, board, status, score } = get();
    if (status !== STATUS.PLAYING || !pac) return false;
    const d = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] }[pac.dir];
    const nx = pac.x + d[0];
    const ny = pac.y + d[1];
    if (nx < 0 || nx >= COLS || ny < 0 || ny >= ROWS) return false; // wall/floor — hold
    let ate = false;
    if (board[ny][nx]) {
      const next = board.map((r) => [...r]);
      next[ny][nx] = null;
      set({ board: next, pac: { ...pac, x: nx, y: ny }, ...scorePatch(get(), score + PAC_EAT_POINTS) });
      ate = true;
    } else {
      set({ pac: { ...pac, x: nx, y: ny } });
    }
    return ate;
  },

  // End of the frenzy: let the columns collapse so blocks left floating after the
  // chomping fall in to fill the gaps (reusing the post-blast fall animation),
  // then spawn the next piece. If nothing moved, spawn immediately.
  finishPac() {
    const state = get();
    if (!state.pac) return;
    const { board, fall } = collapseColumns(state.board);
    if (fall.length === 0) {
      // Nothing to settle — hold a short beat, then spawn (spawnNext).
      set({ board, pac: null, fall: null, pendingSpawn: true });
      return;
    }
    // Board is already settled; the component animates `fall`, then finishFall().
    set({ board, pac: null, fall });
  },

  // Spawn the next piece after a post-power-up hold (the 0.5s beat the component
  // times once a bomb/Pac-Man has fully resolved). Tops out if it can't spawn.
  spawnNext() {
    const state = get();
    if (!state.pendingSpawn) return;
    const nx = takeNext(state);
    if (!isValid(state.board, nx.piece)) {
      set({ pendingSpawn: false, piece: null, status: STATUS.OVER });
      return;
    }
    set({ pendingSpawn: false, queue: nx.queue, bombIn: nx.bombIn, pacIn: nx.pacIn, bombArmed: nx.bombArmed, pacArmed: nx.pacArmed, piece: nx.piece, canHold: true });
  },

  // Debug (tilde mode): force the next spawned piece to be a bomb.
  armBomb() { if (get().status === STATUS.PLAYING) set({ bombArmed: true }); },
  // Debug (tilde mode): force the next spawned piece to be a Pac-Man.
  armPacman() { if (get().status === STATUS.PLAYING) set({ pacArmed: true }); },
}), {
  name: DROPBLOCK_STATE,
  version: 2,
  storage: createJSONStorage(safeStorage),
  // Only the all-time best survives reloads — never an in-progress game. Every
  // empty pane starts idle; a game begins only when you press Enter, and leaving
  // the pane ends it. (The default shallow merge overlays `best` onto the fresh,
  // idle initial state.)
  partialize: (s) => ({ best: s.best }),
  // v1 persisted the full board/status, which would resurrect a paused game once
  // after upgrading — drop everything but the best score.
  migrate: (persisted) => ({ best: persisted?.best ?? 0 }),
}));

// Cells of the ghost (landing preview) for the current piece.
export function ghostCells(board, piece) {
  if (!piece) return [];
  return pieceCells(dropToFloor(board, piece));
}

// ── Native resume (serialise / hydrate the full game) ──────────────────────
// The web empty-state never resurrects a game (partialize keeps only `best`), but
// the native WebView overlay wants to continue exactly where the player left off.
// The host (iOS) reads serializeGame() and stores it, then injects it back via
// hydrateGame() on the next open. Only stable fields are carried — transient
// animation state (clearing/blast/fall/pac/pendingSpawn) is reset on hydrate.
const SAVE_FIELDS = [
  'status', 'score', 'lines', 'level', 'best', 'prevBest', 'beat',
  'board', 'piece', 'queue', 'hold', 'canHold', 'bombIn', 'pacIn',
];

export function serializeGame() {
  const s = useDropBlockStore.getState();
  const out = {};
  for (const k of SAVE_FIELDS) out[k] = s[k];
  return out;
}

export function hydrateGame(data) {
  if (!data || typeof data !== 'object') return;
  const patch = {};
  for (const k of SAVE_FIELDS) if (k in data) patch[k] = data[k];
  // Never restore mid-animation transients — start the resumed game clean.
  patch.clearing = null; patch.blast = null; patch.fall = null;
  patch.pac = null; patch.pendingSpawn = false; patch.bombArmed = false; patch.pacArmed = false;
  useDropBlockStore.setState(patch);
  // A saved snapshot taken mid-animation can have no active piece — spawn one so
  // a resumed PLAYING game isn't stuck pieceless.
  const s = useDropBlockStore.getState();
  if (s.status === STATUS.PLAYING && !s.piece) {
    const queue = refillQueue([...(s.queue || [])]);
    const type = queue.shift();
    useDropBlockStore.setState({ queue, piece: spawnPiece(type), canHold: true });
  }
}

export default useDropBlockStore;
