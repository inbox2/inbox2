/* global process */
// Colour literals in CSS modules may only go DOWN.
//
// Every hex / rgb() / hsl() literal in a *.module.css that is not a token value
// (tokens.css, management.css) and not an allow-listed bevel/hairline pattern
// counts against its file. The counts are pinned in color-literals.baseline.json;
// a file that grows a new literal fails here. After an agreed sweep, re-pin:
//
//   UPDATE_COLOR_BASELINE=1 yarn test
//
// Allow-listed on purpose: white/black washes (`rgba(255,255,255,.0x)` inset
// highlights, `rgba(0,0,0,…)` shadows) and plain #fff/#000 hairlines — the
// Aero bevel language is literal by design.
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const srcDir = path.resolve(here, '../..');
const BASELINE = path.join(here, 'color-literals.baseline.json');

const LITERAL = /#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?)\([^)]*\)/gi;
const ALLOW = [/^rgba?\(255,255,255[,)]/, /^rgba?\(0,0,0[,)]/, /^#(?:fff|ffffff|000|000000)$/];
const norm = (s) => s.toLowerCase().replace(/\s+/g, '');
const stripComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');

function cssFiles(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) return cssFiles(full);
    return full.endsWith('.css') ? [full] : [];
  });
}

const tokenValues = new Set(
  ['styles/tokens.css', 'styles/management.css']
    .flatMap((f) => stripComments(readFileSync(path.join(srcDir, f), 'utf8')).match(LITERAL) || [])
    .map(norm),
);

function strays(file) {
  const text = stripComments(readFileSync(file, 'utf8'));
  return (text.match(LITERAL) || [])
    .map(norm)
    .filter((lit) => !tokenValues.has(lit) && !ALLOW.some((re) => re.test(lit)));
}

const counts = {};
const found = {};
for (const file of cssFiles(srcDir).filter((f) => f.endsWith('.module.css')).sort()) {
  const rel = path.relative(srcDir, file);
  const list = strays(file);
  if (list.length) { counts[rel] = list.length; found[rel] = list; }
}

describe('colour literals in CSS modules', () => {
  it('never increase per file (see color-literals.baseline.json)', () => {
    if (process.env.UPDATE_COLOR_BASELINE) {
      writeFileSync(BASELINE, JSON.stringify(counts, null, 2) + '\n');
      return;
    }
    const baseline = JSON.parse(readFileSync(BASELINE, 'utf8'));
    const grew = Object.entries(counts)
      .filter(([file, n]) => n > (baseline[file] ?? 0))
      .map(([file, n]) => `${file}: ${n} > ${baseline[file] ?? 0} — ${[...new Set(found[file])].join(' ')}`);
    expect(grew).toEqual([]);
  });
});
