import { describe, it, expect } from 'vitest';
import { matchesPaletteKey } from '../usePaletteShortcut';

const ev = (o) => ({ key: 'p', code: 'KeyP', metaKey: false, ctrlKey: false, altKey: false, repeat: false, ...o });

describe('matchesPaletteKey', () => {
  it('fires for ⌘P and Ctrl+P', () => {
    expect(matchesPaletteKey(ev({ metaKey: true }))).toBe(true);
    expect(matchesPaletteKey(ev({ ctrlKey: true }))).toBe(true);
  });

  it('fires with Shift / Caps Lock and on non-Latin layouts', () => {
    expect(matchesPaletteKey(ev({ metaKey: true, key: 'P' }))).toBe(true);
    expect(matchesPaletteKey(ev({ metaKey: true, key: 'з' }))).toBe(true);
  });

  it('ignores bare P, Alt combos and auto-repeat', () => {
    expect(matchesPaletteKey(ev({}))).toBe(false);
    expect(matchesPaletteKey(ev({ metaKey: true, altKey: true }))).toBe(false);
    expect(matchesPaletteKey(ev({ ctrlKey: true, altKey: true }))).toBe(false);
    expect(matchesPaletteKey(ev({ metaKey: true, repeat: true }))).toBe(false);
  });

  it('ignores other keys', () => {
    expect(matchesPaletteKey(ev({ metaKey: true, key: 'k', code: 'KeyK' }))).toBe(false);
    expect(matchesPaletteKey(ev({ metaKey: true, key: undefined, code: 'KeyK' }))).toBe(false);
  });
});
