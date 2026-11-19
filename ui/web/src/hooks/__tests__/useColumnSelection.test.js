// @vitest-environment jsdom
//
// Multi-select gestures for the column views. No @testing-library in this repo,
// so the hook runs in a bare React root — small enough not to need one.
import { describe, it, expect } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';
import useColumnSelection from '../useColumnSelection';

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

function renderHook(hook) {
  const ref = { current: null };
  const Probe = () => { ref.current = hook(); return null; };
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe)));
  return { get: () => ref.current, run: (fn) => { let out; act(() => { out = fn(ref.current); }); return out; } };
}

const col = (key, n) => Array.from({ length: n }, (_, i) => ({ id: `${key}-${i}`, accountKey: key }));
const A = col('a', 5);
const B = col('b', 3);

describe('useColumnSelection', () => {
  it('cmd-click toggles rows; a plain click clears and opens instead', () => {
    const h = renderHook(useColumnSelection);
    h.run(s => s.handleRowClick(A[0], { metaKey: true }, A, 0));
    h.run(s => s.handleRowClick(A[2], { metaKey: true }, A, 2));
    expect([...h.get().selectedIds]).toEqual(['a-0', 'a-2']);

    h.run(s => s.handleRowClick(A[2], { metaKey: true }, A, 2));
    expect([...h.get().selectedIds]).toEqual(['a-0']);

    // false = not a selection gesture, so the caller opens the row.
    expect(h.run(s => s.handleRowClick(A[1], {}, A, 1))).toBe(false);
    expect(h.get().selectedIds.size).toBe(0);
  });

  it('shift-click extends a range from the anchor', () => {
    const h = renderHook(useColumnSelection);
    h.run(s => s.handleRowClick(A[3], {}, A, 3));
    h.run(s => s.handleRowClick(A[1], { shiftKey: true }, A, 1));
    expect([...h.get().selectedIds]).toEqual(['a-1', 'a-2', 'a-3']);
  });

  it('a batch never spans two columns', () => {
    const h = renderHook(useColumnSelection);
    h.run(s => s.handleRowClick(A[0], { metaKey: true }, A, 0));
    h.run(s => s.handleRowClick(B[1], { metaKey: true }, B, 1));
    expect([...h.get().selectedIds]).toEqual(['b-1']);

    // Shift against an anchor in the other column is a plain click, not a range.
    h.run(s => s.handleRowClick(A[2], { shiftKey: true }, A, 2));
    expect(h.get().selectedIds.size).toBe(0);
  });

  it('right-click keeps a batch it belongs to, drops one it does not', () => {
    const h = renderHook(useColumnSelection);
    h.run(s => s.handleRowClick(A[0], { metaKey: true }, A, 0));
    h.run(s => s.keepOrResetSelection(A[0]));
    expect(h.get().selectedIds.has('a-0')).toBe(true);

    h.run(s => s.keepOrResetSelection(A[4]));
    expect(h.get().selectedIds.size).toBe(0);
  });
});
