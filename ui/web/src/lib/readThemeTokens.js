// Read resolved CSS custom-property (theme token) values off :root by name, e.g.
//   const { '--accent': accent } = readThemeTokens(['--accent', '--bg-base']);
// Replaces the duplicated getComputedStyle(document.documentElement) readers in
// CommandCenterPage / ThemeSettings.
export function readThemeTokens(names) {
  const cs = getComputedStyle(document.documentElement);
  const out = {};
  for (const name of names) out[name] = cs.getPropertyValue(name).trim();
  return out;
}
