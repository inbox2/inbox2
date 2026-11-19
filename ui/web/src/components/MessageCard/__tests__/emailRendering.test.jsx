// @vitest-environment jsdom
//
// Web/desktop wrapper harness: the iframe document EmailFrame builds for HTML
// emails. The shared @inbox2/email-body engine (quote/signature/remote-block) is
// covered fixture-by-fixture in packages/email-body/__tests__/fixtures.test.js;
// here we assert the things the WRAPPER owns and that have had zero coverage:
//   - the CSP posture (strict by default, relaxed only on consented direct render)
//   - the FRAME_FIT_CSS backstop that fixes clipped/collapsed auto-height
//   - quote/signature collapse into native <details>, with forwards auto-expanded
//   - <style> sanitization (@import + remote url() neutralized)
// Real example emails come from the shared /fixtures/email corpus.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { buildSrcDoc, isNearWhite } from '../buildSrcDoc';

// The shared corpus lives at the repo root (six levels up from this __tests__ dir).
const casesDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../../../fixtures/email/cases');
const fixture = (name) => readFileSync(path.join(casesDir, name), 'utf8');

describe('EmailFrame.buildSrcDoc — CSP posture', () => {
  const html = fixture('tracking-pixel.html');

  it('blocks all remote loads by default (strict CSP, proxy-only)', () => {
    const doc = buildSrcDoc(html, false);
    expect(doc).toContain('img-src data: blob:;');
    // The CSP itself must not admit remote schemes (a stashed data-blocked-src may
    // still carry the original https URL — that's inert, not a load directive).
    expect(doc).not.toContain('img-src data: blob: https:');
  });

  it('admits https/http images only on the consented direct render', () => {
    const doc = buildSrcDoc(html, true);
    expect(doc).toContain('img-src data: blob: https: http:;');
  });

  it('neutralizes the tracking pixel and stashes the original for restore', () => {
    const doc = buildSrcDoc(html, false);
    expect(doc).toContain('data-blocked-src="https://track.example/o.gif"');
    expect(doc).not.toMatch(/\ssrc=["']https?:/i);
  });
});

describe('EmailFrame.buildSrcDoc — auto-height backstop', () => {
  it('injects FRAME_FIT_CSS last so it wins the cascade (TikTok clip/collapse fix)', () => {
    const doc = buildSrcDoc(fixture('tiktok-float.html'), false);
    expect(doc).toContain('height:auto!important');
    expect(doc).toContain('display:flow-root!important');
    // It must come AFTER the email's own styles to override their !important rules.
    expect(doc.lastIndexOf('flow-root')).toBeGreaterThan(doc.indexOf('<body>'));
  });
});

describe('EmailFrame.buildSrcDoc — quote/signature collapse', () => {
  it('collapses a quoted reply into a <details> (kept closed when there is a real body)', () => {
    const doc = buildSrcDoc(fixture('gmail-quote.html'), false);
    expect(doc).toContain('<details');
    expect(doc).toContain('Quoted text');
    expect(doc).not.toMatch(/<details open><summary>Quoted text/);
  });

  it('collapses a signature into a closed <details>', () => {
    const doc = buildSrcDoc(fixture('gmail-signature.html'), false);
    expect(doc).toContain('<details');
    expect(doc).toContain('Signature');
  });

  it('auto-expands the quote when the body is empty (bare forward, nothing but the quote)', () => {
    // EmailFrame opens the quote only when the body has no real text of its own.
    const doc = buildSrcDoc('<blockquote type="cite">forwarded content with no added note</blockquote>', false);
    expect(doc).toMatch(/<details open/);
  });

  it('keeps the quote closed when a forward has a preamble line above it', () => {
    // The forward-only fixture has a "Begin forwarded message:" line outside the
    // quote, so the body is not empty — EmailFrame leaves the quote collapsed.
    // (QuotedText strips that forward noise and would expand; EmailFrame does not.)
    const doc = buildSrcDoc(fixture('forward-only.html'), false);
    expect(doc).toContain('<details><summary>Quoted text');
  });
});

describe('EmailFrame.buildSrcDoc — <style> sanitization', () => {
  it('strips @import and neutralizes remote url() in email CSS', () => {
    const html =
      '<div>Hi</div>' +
      '<style>@import url(https://evil.example/x.css); .a{background:url(https://t.example/bg.png)}</style>';
    const doc = buildSrcDoc(html, false);
    expect(doc).not.toContain('@import');
    expect(doc).not.toContain('evil.example');
    expect(doc).not.toContain('t.example/bg.png');
  });
});

// Regression: a prose email that paints its own WHITE background (background:white on
// every <p>) was wrongly treated as a full-bleed, self-styled design, so EmailFrame
// dropped the reading padding and the text ran flush against the card edges. The
// padding decision keys off isNearWhite(): a near-white self-background must NOT count
// as full-bleed, so the white reading page + 16px padding stay. (Mirrors iOS.)
describe('EmailFrame — near-white background keeps reading padding', () => {
  it('treats white / near-white backgrounds as NOT full-bleed', () => {
    expect(isNearWhite('white')).toBe(true);             // keyword form
    expect(isNearWhite('rgb(255, 255, 255)')).toBe(true);
    expect(isNearWhite('rgb(245, 247, 250)')).toBe(true); // PayPal-ish off-white
    expect(isNearWhite('rgb(236, 236, 236)')).toBe(true); // threshold
  });

  it('treats genuinely colored / dark backgrounds as full-bleed', () => {
    expect(isNearWhite('rgb(20, 20, 30)')).toBe(false);
    expect(isNearWhite('rgb(123, 108, 246)')).toBe(false); // violet brand
    expect(isNearWhite('rgba(0, 0, 0, 0)')).toBe(false);   // transparent
    expect(isNearWhite('')).toBe(false);
  });

  it('the book-club fixture paints itself white on every block (the trigger)', () => {
    const html = fixture('white-bg-no-padding.html');
    // Every paragraph carries background:white but no padding — so the email relies on
    // the reader for spacing. If isNearWhite stops recognizing white, the reader would
    // strip padding and this email squishes to the edges again.
    expect(html).toContain('background:white');
    expect(isNearWhite('rgb(255,255,255)')).toBe(true);
  });
});
