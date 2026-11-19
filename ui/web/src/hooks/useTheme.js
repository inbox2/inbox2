import { useSyncExternalStore, useCallback } from 'react';
import {
  THEMES,
  THEME_MODE,
  DEFAULT_THEME_ID,
  getTheme,
  applyTheme,
  getUserOverrides,
  setUserOverride,
  clearUserOverrides,
  exportTheme,
  importTheme,
  resolveThemeBackground,
  getBackgroundPref,
  setBackgroundPref,
  clearBackground,
  getTextScale,
  setTextScale as persistTextScale,
} from '../lib/themes';
import { THEME as STORAGE_KEY } from '../lib/storageKeys';
import { setAppIcon } from '../lib/appIcon';

// Module-level shared state — single source of truth for all useTheme consumers.
let _themeId = localStorage.getItem(STORAGE_KEY) || DEFAULT_THEME_ID;
// Monotonic tick bumped on any change (theme switch OR override edit) so
// useSyncExternalStore re-renders subscribers; the data itself lives in
// themes.js (localStorage) and is read fresh each render.
let _version = 0;
const _listeners = new Set();

function _notify() {
  _version += 1;
  for (const fn of _listeners) fn();
}

function _apply(nextId) {
  // data-theme (mode) + data-theme-variant + per-variant overrides + the user's
  // per-theme token customizations. Shared with the boot path (main.jsx) so every
  // screen — incl. the pre-app login/onboarding pages — gets the same look.
  const theme = applyTheme(nextId);
  _themeId = theme.id;
  localStorage.setItem(STORAGE_KEY, theme.id);
  _notify();
}

// Set the root attributes immediately (before any component mounts).
_apply(_themeId);

/**
 * Shared theme hook — all instances read from the same module-level state.
 *
 * Returns:
 *   theme          resolved theme object (id, label, mode, background, swatch, …)
 *   themeId        active theme id
 *   mode           'dark' | 'light' — convenient for `data-theme` and light/dark checks
 *   themes         the full registry (for pickers)
 *   overrides      the active theme's user token overrides ({ '--token': value })
 *   setTheme       select a theme by id
 *   toggleTheme    legacy light/dark flip (used by the command palette)
 *   setOverride    set/clear one token override on the active theme
 *   resetOverrides drop all overrides on the active theme
 */
export default function useTheme() {
  useSyncExternalStore(
    (cb) => { _listeners.add(cb); return () => _listeners.delete(cb); },
    () => _version,
  );

  const themeId = _themeId;
  // Resolve the render background (custom image overrides the shipped backdrop).
  const theme = resolveThemeBackground(getTheme(themeId));
  const overrides = getUserOverrides(themeId);
  const background = getBackgroundPref(themeId);

  // A user's theme pick (not the boot path): a theme that carries its own app
  // icon switches to it on the way in; a manual icon choice afterwards sticks.
  const setTheme = useCallback((id) => {
    const icon = id !== _themeId ? getTheme(id).appIcon : null;
    _apply(id);
    if (icon) setAppIcon(icon);
  }, []);

  const toggleTheme = useCallback(() => {
    const cur = getTheme(_themeId);
    _apply(cur.mode === THEME_MODE.DARK ? 'light' : DEFAULT_THEME_ID);
  }, []);

  const setOverride = useCallback((key, value) => {
    setUserOverride(_themeId, key, value);
    _apply(_themeId);
  }, []);

  const resetOverrides = useCallback(() => {
    clearUserOverrides(_themeId);
    _apply(_themeId);
  }, []);

  // Export the active theme as a shareable object.
  const exportCurrent = useCallback(() => exportTheme(_themeId), []);

  // Import a shared theme: persists its overrides and activates its base theme.
  // Throws on invalid input (caller surfaces the message).
  const importShared = useCallback((data) => {
    const baseId = importTheme(data);
    _apply(baseId);
  }, []);

  // Background: switch mode, set a custom image (data URL), or clear it. Each
  // re-applies so DotMatrix re-renders the backdrop.
  const setBackgroundMode = useCallback((mode) => {
    setBackgroundPref(_themeId, { mode });
    _apply(_themeId);
  }, []);

  const setCustomBackground = useCallback((dataUrl) => {
    setBackgroundPref(_themeId, { mode: 'custom', image: dataUrl });
    _apply(_themeId);
  }, []);

  const clearCustomBackground = useCallback(() => {
    clearBackground(_themeId);
    _apply(_themeId);
  }, []);

  // Text size — global, not per-theme; _notify so every subscriber re-renders.
  const setTextScale = useCallback((value) => {
    persistTextScale(value);
    _notify();
  }, []);

  return {
    theme,
    themeId,
    mode: theme.mode,
    themes: THEMES,
    overrides,
    setTheme,
    toggleTheme,
    setOverride,
    resetOverrides,
    exportCurrent,
    importShared,
    background,
    setBackgroundMode,
    setCustomBackground,
    clearCustomBackground,
    textScale: getTextScale(),
    setTextScale,
  };
}
