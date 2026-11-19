// Theme tokens referenced by CSS modules must actually exist.
//
// `var(--surface-sunken, rgba(0,0,0,.2))` looks fine and lints fine, but if the
// token was never defined, EVERY use silently takes its fallback — and those
// fallbacks are written while looking at dark mode, so the light theme renders
// grey blobs. That shipped in the rule editor, the triage lab, the agents card
// and the search filters before anyone noticed.
//
// Only the families whose VALUE differs between light and dark are checked —
// those are the ones a dark-eyed fallback silently breaks. Sizes, radii and
// easings are theme-independent, and runtime custom properties (--tip-x,
// --status-color, --brand-accent…) are SUPPOSED to be undefined in CSS and set
// per element via a ref; both are out of scope.
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const srcDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const THEME_FAMILIES = /^--(surface|bg|text|border|overlay)-/;

function cssFiles(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) return cssFiles(full);
    return full.endsWith('.css') ? [full] : [];
  });
}

const files = cssFiles(srcDir);

const defined = new Set(
  files.flatMap(f => [...readFileSync(f, 'utf8').matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)].map(m => m[1]))
);

describe('design tokens', () => {
  it('defines every theme token that CSS modules fall back on', () => {
    const orphans = [];
    for (const file of files) {
      const text = readFileSync(file, 'utf8');
      for (const match of text.matchAll(/var\((--[a-z0-9-]+)\s*,/g)) {
        const token = match[1];
        if (!THEME_FAMILIES.test(token) || defined.has(token)) continue;
        orphans.push(`${token} → ${path.relative(srcDir, file)}`);
      }
    }
    expect([...new Set(orphans)]).toEqual([]);
  });

  it('defines the sunken surface in both themes', () => {
    const tokens = readFileSync(path.join(srcDir, 'styles/tokens.css'), 'utf8');
    expect([...tokens.matchAll(/^\s*--surface-sunken\s*:/gm)]).toHaveLength(2);
  });
});
