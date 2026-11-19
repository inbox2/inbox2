// @vitest-environment jsdom
//
// Look step: dark or light first, then only that mode's themes.
import { describe, it, expect, afterEach } from 'vitest';
import { createRoot } from 'react-dom/client';
import { act } from 'react';
import ThemeStep from '../steps/ThemeStep';
import { THEMES } from '../../../lib/themes';

let root;
afterEach(() => { act(() => root?.unmount()); document.body.innerHTML = ''; });

const mount = () => {
  const host = document.createElement('div');
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root.render(<ThemeStep onContinue={() => {}} />));
  return host;
};

const themeNames = (host) =>
  [...host.querySelectorAll('[aria-label="Theme"] [role="radio"]')].map(b => b.textContent);

describe('ThemeStep', () => {
  it('lists only the chosen mode\'s themes and switches mode on click', () => {
    const host = mount();
    const dark = THEMES.filter(t => t.mode === 'dark').map(t => t.label);
    const light = THEMES.filter(t => t.mode === 'light').map(t => t.label);
    expect(themeNames(host).every(n => dark.some(l => n.startsWith(l)))).toBe(true);

    const lightBtn = [...host.querySelectorAll('[aria-label="Mode"] [role="radio"]')].find(b => b.textContent.startsWith('Light'));
    act(() => lightBtn.click());
    expect(document.documentElement.getAttribute('data-theme')).toBe('light');
    expect(themeNames(host).map(n => light.find(l => n.startsWith(l)))).toEqual(light);
  });
});
