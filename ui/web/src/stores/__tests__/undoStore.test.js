// @vitest-environment jsdom
//
// The batching contract a mass action relies on: N records sharing one token
// collapse into one toast and one undo that unwinds every row.
import { describe, it, expect, beforeEach } from 'vitest';
import useUndoStore from '../undoStore';

const reset = () => useUndoStore.setState({ undoStack: [], redoStack: [], toasts: [] });

describe('undoStore batching', () => {
  beforeEach(reset);

  it('folds a batch into one toast and one undo', async () => {
    const store = useUndoStore.getState();
    const batch = Symbol('bulk');
    const undone = [];
    for (const n of [1, 2, 3]) {
      store.record({
        batch,
        description: `Deleted "mail ${n}"`,
        undo: () => undone.push(n),
        redo: () => {},
      });
    }

    const state = useUndoStore.getState();
    expect(state.toasts).toHaveLength(1);
    expect(state.undoStack).toHaveLength(1);
    expect(state.toasts[0].description).toBe('Deleted "mail 1" + 2 more');

    await useUndoStore.getState().undo();
    // Reverse order, and every row — not just the last one recorded.
    expect(undone).toEqual([3, 2, 1]);
    expect(useUndoStore.getState().undoStack).toHaveLength(0);
    expect(useUndoStore.getState().toasts).toHaveLength(0);
  });

  it('uses the record site\'s plural copy, not the first row\'s subject', () => {
    const store = useUndoStore.getState();
    const batch = Symbol('bulk');
    for (const n of [1, 2, 3]) {
      store.record({
        batch,
        description: `Deleted "a long subject that would truncate ${n}"`,
        batchDescription: (count) => `Deleted ${count} conversations`,
        undo: () => {},
        redo: () => {},
      });
    }
    expect(useUndoStore.getState().toasts[0].description).toBe('Deleted 3 conversations');
  });

  it('leaves unbatched records alone', async () => {
    const store = useUndoStore.getState();
    const undone = [];
    store.record({ description: 'a', undo: () => undone.push('a'), redo: () => {} });
    store.record({ description: 'b', undo: () => undone.push('b'), redo: () => {} });
    expect(useUndoStore.getState().toasts).toHaveLength(2);

    await useUndoStore.getState().undo();
    expect(undone).toEqual(['b']);
  });

  it('a separate batch token starts a new toast', () => {
    const store = useUndoStore.getState();
    const first = Symbol('bulk');
    const second = Symbol('bulk');
    store.record({ batch: first, description: 'x', undo: () => {}, redo: () => {} });
    store.record({ batch: second, description: 'y', undo: () => {}, redo: () => {} });
    expect(useUndoStore.getState().toasts).toHaveLength(2);
  });

  it('redo re-applies every row of a batch, in order', async () => {
    const store = useUndoStore.getState();
    const batch = Symbol('bulk');
    const redone = [];
    for (const n of [1, 2]) {
      store.record({ batch, description: `d${n}`, undo: () => {}, redo: () => redone.push(n) });
    }
    await useUndoStore.getState().undo();
    await useUndoStore.getState().redo();
    expect(redone).toEqual([1, 2]);
  });
});
