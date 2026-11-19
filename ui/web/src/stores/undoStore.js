import { create } from 'zustand';

// Global command-history store for undoable email actions.
//
// Every state-changing action (archive/trash/spam/mark/triage) routes through a
// dispatcher (useConversationActions, useUnifiedInbox) that calls `record()` with
// an inverse `undo` and a re-apply `redo`. Cmd+Z / Cmd+Y are bound globally below
// so undo/redo work from any view. A 7s toast (UndoToast) surfaces the most recent
// action; the command history itself persists (capped) for keyboard undo/redo.

const TOAST_MS = 7000;
const MAX_HISTORY = 50;

// Per-toast auto-dismiss timers, kept outside React state.
const timers = new Map();
let nextId = 1;

const useUndoStore = create((set, get) => ({
  undoStack: [],
  redoStack: [],
  toasts: [],

  // Record a freshly-performed action. `undo`/`redo` are async fns that re-apply
  // the inverse / original without recording again.
  //
  // `batch` is an opaque token shared by every record of one mass action. The
  // per-conversation dispatchers record once per row, so without this a 35-row
  // delete would stack 35 toasts and need 35 undos; records sharing a token fold
  // into the command the first one created — one toast, one undo, all 35 rows.
  // `batchDescription(n)` is the copy for the folded command — a per-row subject
  // would just truncate away the count ("Deleted "Choithrams has accep…"), so
  // each record site phrases its own plural instead.
  record({ description, batchDescription = null, variant = null, icon = null, key = null, undo, redo, batch = null }) {
    const top = get().undoStack[get().undoStack.length - 1];

    if (batch && top && top.batch === batch) {
      const parts = [...top.parts, { undo, redo }];
      const merged = {
        ...top,
        parts,
        description: top.batchDescription?.(parts.length) || `${top.baseDescription} + ${parts.length - 1} more`,
      };
      set(state => ({
        undoStack: [...state.undoStack.slice(0, -1), merged],
        toasts: state.toasts.map(t => t.id === top.id ? { ...t, description: merged.description } : t),
      }));
      // The toast's 7s runs from the last row of the batch, not the first.
      clearTimeout(timers.get(top.id));
      timers.set(top.id, setTimeout(() => get()._removeToast(top.id), TOAST_MS));
      return top.id;
    }

    const id = nextId++;
    const command = { id, description, baseDescription: description, batchDescription, variant, icon, key, batch, parts: [{ undo, redo }] };

    set(state => ({
      undoStack: [...state.undoStack, command].slice(-MAX_HISTORY),
      redoStack: [], // any new action invalidates the redo branch
      toasts: [{ id, description, variant, icon, undoable: true }, ...state.toasts],
    }));

    timers.set(id, setTimeout(() => {
      get()._removeToast(id);
    }, TOAST_MS));

    return id;
  },

  // Surface a message that is NOT an undoable command — used when an action
  // failed to reach the server. Same toast machinery, but nothing goes on the
  // undo stack: there's nothing to reverse, and pushing a no-op command would
  // make Cmd+Z undo the wrong thing (the last action that actually happened).
  // The toast renders without an Undo button.
  notify({ description, variant = null, icon = null }) {
    const id = nextId++;
    set(state => ({ toasts: [{ id, description, variant, icon, undoable: false }, ...state.toasts] }));
    timers.set(id, setTimeout(() => get()._removeToast(id), TOAST_MS));
    return id;
  },

  // Undo the most recent command, or a specific one (e.g. a toast's Undo button).
  async undo(id) {
    const { undoStack } = get();
    if (undoStack.length === 0) return;
    const command = id != null
      ? undoStack.find(c => c.id === id)
      : undoStack[undoStack.length - 1];
    if (!command) return;

    set(state => ({
      undoStack: state.undoStack.filter(c => c.id !== command.id),
      redoStack: [...state.redoStack, command],
    }));
    get()._removeToast(command.id);

    // Reverse order so a batch unwinds the way it was applied.
    for (const part of [...command.parts].reverse()) {
      try { await part.undo(); } catch { /* undo failed silently */ }
    }
  },

  // Re-apply the most recently undone command.
  async redo() {
    const { redoStack } = get();
    if (redoStack.length === 0) return;
    const command = redoStack[redoStack.length - 1];

    set(state => ({
      redoStack: state.redoStack.filter(c => c.id !== command.id),
      undoStack: [...state.undoStack, command].slice(-MAX_HISTORY),
    }));

    for (const part of command.parts) {
      try { await part.redo(); } catch { /* redo failed silently */ }
    }
  },

  // Dismiss a toast without undoing (the command stays in history).
  dismiss(id) {
    get()._removeToast(id);
  },

  _removeToast(id) {
    const t = timers.get(id);
    if (t) { clearTimeout(t); timers.delete(id); }
    set(state => ({ toasts: state.toasts.filter(e => e.id !== id) }));
  },
}));

// ── Global keyboard: Cmd/Ctrl+Z undo, Cmd/Ctrl+Y or Cmd/Ctrl+Shift+Z redo ──
// Bound once at module load, in the capture phase so it beats component handlers.
// Skipped while typing so Cmd+Z stays as text-undo in inputs/editors.
if (typeof window !== 'undefined' && !window.__inbox2UndoBound) {
  window.__inbox2UndoBound = true;
  window.addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    const el = document.activeElement;
    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;

    const key = e.key.toLowerCase();
    const isRedo = (key === 'z' && e.shiftKey) || (key === 'y' && !e.shiftKey);
    const isUndo = key === 'z' && !e.shiftKey;
    if (!isRedo && !isUndo) return;

    const store = useUndoStore.getState();
    if (isRedo) {
      if (store.redoStack.length === 0) return;
      e.preventDefault();
      e.stopPropagation();
      store.redo();
    } else {
      if (store.undoStack.length === 0) return;
      e.preventDefault();
      e.stopPropagation();
      store.undo();
    }
  }, true);
}

export default useUndoStore;
