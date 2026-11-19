// @vitest-environment jsdom
//
// Fixture-driven harness for the shared email body pipeline. Every rendering case
// we handle has ONE real example email under /fixtures/email/cases, declared in
// /fixtures/email/manifest.json with its expected outcome. This runs each fixture
// through processBody() — the SAME entry point the desktop iframe, the iOS WKWebView
// and the Android WebView all call — so a regression in quote/signature detection,
// <pre> unwrapping, or remote-content blocking fails here for every platform at once.
//
// Add a rendering case => drop an .html in cases/ + a manifest entry. No code change.
import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { processBody } from '../src/index.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixturesDir = path.resolve(here, '../../../fixtures/email');
const manifest = JSON.parse(readFileSync(path.join(fixturesDir, 'manifest.json'), 'utf8'));

const load = (file) => readFileSync(path.join(fixturesDir, file), 'utf8');

describe('email-body fixtures (manifest)', () => {
  it('every fixture file is declared in the manifest (no orphans)', () => {
    const onDisk = readdirSync(path.join(fixturesDir, 'cases')).filter(f => f.endsWith('.html')).sort();
    const declared = manifest.cases.map(c => path.basename(c.file)).sort();
    expect(onDisk).toEqual(declared);
  });

  for (const c of manifest.cases) {
    describe(c.name, () => {
      const html = load(c.file);
      const e = c.expect || {};
      const out = processBody(html); // default block: true — the privacy-on path

      it(`title: ${c.title}`, () => {
        expect(typeof html).toBe('string');
        expect(html.length).toBeGreaterThan(0);
      });

      it(`hasQuote == ${!!e.hasQuote}`, () => {
        expect(out.hasQuote).toBe(!!e.hasQuote);
      });

      it(`hasSignature == ${!!e.hasSignature}`, () => {
        expect(out.hasSignature).toBe(!!e.hasSignature);
      });

      it(e.blocksRemote ? 'blocks remote content (count > 0)' : 'blocks no remote content (count == 0)', () => {
        if (e.blocksRemote) expect(out.blockedCount).toBeGreaterThan(0);
        else expect(out.blockedCount).toBe(0);
      });

      // Universal privacy invariant: opening a message must never leave a live
      // remote `src` in the rendered HTML — every one is neutralized to a data:
      // placeholder with the original stashed on data-blocked-src for restore.
      it('leaves no live remote image src', () => {
        expect(out.html).not.toMatch(/\ssrc=["']https?:/i);
      });

      if (e.unwrapsPre) {
        it('unwraps the <pre>-wrapped document', () => {
          expect(out.html).not.toMatch(/<pre[\s>]/i);
        });
      }

      for (const needle of e.contains || []) {
        it(`output contains: ${needle}`, () => {
          expect(out.html).toContain(needle);
        });
      }

      for (const needle of e.notContains || []) {
        it(`output does NOT contain: ${needle}`, () => {
          expect(out.html).not.toContain(needle);
        });
      }
    });
  }
});
