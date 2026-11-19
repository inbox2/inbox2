// @vitest-environment jsdom
//
// The three pane modes and the floating dismiss rule. Bare React root, same
// as useColumnSelection.test.js.
import { describe, it, expect, beforeEach } from 'vitest';
import { createElement, act, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import usePaneMode, { PANE_MODE } from '../usePaneMode';

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

function renderPane(ignore) {
  const out = { current: null };
  const root = document.createElement('div');
  root.id = 'root';
  document.body.appendChild(root);
  const inside = document.createElement('div');
  root.appendChild(inside);
  const outside = document.createElement('div');
  root.appendChild(outside);
  const Probe = () => { const ref = useRef(inside); out.current = usePaneMode('k', ref, ignore); return null; };
  act(() => createRoot(document.createElement('div')).render(createElement(Probe)));
  const down = (el) => act(() => { el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); });
  return { get: () => out.current, run: (fn) => act(() => fn(out.current)), down, inside, outside };
}

beforeEach(() => { localStorage.clear(); document.body.innerHTML = ''; });

describe('usePaneMode', () => {
  it('pinned shows, hidden collapses to the strip, floating shows only while open', () => {
    const h = renderPane();
    expect(h.get().shown).toBe(true);
    expect(h.get().strip).toBe(false);

    h.run(p => p.setMode(PANE_MODE.HIDDEN));
    expect(h.get().shown).toBe(false);
    expect(h.get().strip).toBe(true);
    expect(localStorage.getItem('k')).toBe(PANE_MODE.HIDDEN);

    // Picking "floating" opens it so the choice is visible...
    h.run(p => p.setMode(PANE_MODE.FLOATING));
    expect(h.get().shown).toBe(true);
    // ...a click inside keeps it, a click elsewhere in the app dismisses it.
    h.down(h.inside);
    expect(h.get().shown).toBe(true);
    h.down(h.outside);
    expect(h.get().shown).toBe(false);

    h.run(p => p.setOpen(true));
    act(() => { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); });
    expect(h.get().shown).toBe(false);
  });

  it('ignores clicks in portals and on the ignore selector', () => {
    const h = renderPane('[data-row]');
    h.run(p => p.setMode(PANE_MODE.FLOATING));
    const portal = document.createElement('div');
    document.body.appendChild(portal);
    h.down(portal);
    expect(h.get().shown).toBe(true);
    const row = document.createElement('div');
    row.setAttribute('data-row', '');
    h.outside.appendChild(row);
    h.down(row);
    expect(h.get().shown).toBe(true);
  });
});
