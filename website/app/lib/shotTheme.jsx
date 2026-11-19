import { createContext, useCallback, useContext, useEffect, useState } from "react";

// Which palette the app screenshots are shown in. Every screen is captured
// twice (website/scripts/shots.py), so this only picks a file: `<name>.webp`
// for the dark theme, `<name>-light.webp` for the light one.
const KEY = "inbox2_site_shot_theme";
const Ctx = createContext(null);

export const SHOT_THEMES = ["dark", "light"];

export function ShotThemeProvider({ children }) {
  // The pages are prerendered, so the first paint is always dark; the stored
  // choice is applied on mount rather than baked into the HTML.
  const [theme, setTheme] = useState("dark");

  useEffect(() => {
    try {
      const stored = localStorage.getItem(KEY);
      // eslint-disable-next-line react-hooks/set-state-in-effect -- prerendered HTML has no localStorage; the stored choice can only land after mount.
      if (SHOT_THEMES.includes(stored)) setTheme(stored);
    } catch { /* private mode, blocked storage */ }
  }, []);

  // Mirrored onto the document so CSS can react too — the hero reflection has
  // to be tuned per theme and lives in a stylesheet, not in a component.
  useEffect(() => {
    document.documentElement.dataset.shotTheme = theme;
  }, [theme]);

  const choose = useCallback((next) => {
    setTheme(next);
    try {
      localStorage.setItem(KEY, next);
    } catch { /* nothing to do — the choice just doesn't survive a reload */ }
  }, []);

  return <Ctx.Provider value={{ theme, choose }}>{children}</Ctx.Provider>;
}

export function useShotTheme() {
  return useContext(Ctx) || { theme: "dark", choose: () => {} };
}

/** Point a screenshot path at the current theme's variant, either direction. */
export function shotSrc(src, theme) {
  if (!src) return src;
  const dark = src.replace(/-light(\.[a-z0-9]+)$/i, "$1");
  return theme === "light" ? dark.replace(/(\.[a-z0-9]+)$/i, "-light$1") : dark;
}
