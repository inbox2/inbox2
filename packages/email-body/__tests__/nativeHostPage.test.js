// Native host-page contract guard (iOS + Android parity).
//
// The shared bundle is fixture-tested (fixtures.test.js) and kept in sync with the
// native copies (bundleSync.test.js). But each native client also embeds a HOST PAGE
// — an HTML/JS string template in MessageBodyWebView.swift / .kt — that drives the
// bundle: it sets the CSP, calls processBody, collapses quote/signature blocks into
// <details>, runs the self-painted-background detection, reports height, and wires the
// proxy fetch-and-swap. That wiring has no other test. This asserts the critical
// pieces are present in BOTH platforms, so a refactor can't quietly drop one (which
// would break rendering on that platform only). It is a static source check — cheap,
// no simulator — complementing on-device runs.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');

const HOSTS = {
  iOS: path.join(repoRoot, 'ui/ios/Sources/Views/MessageBodyWebView.swift'),
  Android: path.join(repoRoot, 'ui/android/app/src/main/java/com/inbox2/app/ui/components/MessageBodyWebView.kt'),
};

// Each entry: a human label + a substring both host pages must contain. Parity by
// construction — the same contract is asserted against iOS and Android.
const CONTRACT = [
  ['drives the shared bundle', 'Inbox2EmailBody.processBody('],
  ['strict CSP (proxy/blocked default)', 'data: blob:'],
  ['relaxed CSP only for consented direct images', 'data: blob: https:'],
  ['collapses quoted blocks', 'data-quoted-block'],
  ['collapses signature blocks', 'data-signature-block'],
  ['wraps collapses in native <details>', "createElement('details')"],
  ['auto-expands a bare forward', 'r.quotesOnly'],
  ['runs self-painted-background detection', 'applyBackground'],
  ['reports content height for self-sizing', 'ResizeObserver'],
  ['collects blocked URLs for the privacy proxy', 'data-blocked-src'],
];

describe('native host page contract', () => {
  for (const [platform, file] of Object.entries(HOSTS)) {
    describe(platform, () => {
      const src = readFileSync(file, 'utf8');
      for (const [label, needle] of CONTRACT) {
        it(label, () => {
          expect(src).toContain(needle);
        });
      }
    });
  }
});

// The reader CSS lives in a per-platform constant (iOS EmailReaderCSS.swift,
// Android EmailReaderCss.kt). Both scale fixed-width/MJML emails down to fit the
// viewport (Gmail's mobile behaviour) instead of reflowing — keeps fonts/buttons in
// proportion. Parity by construction.
const READER_CSS = {
  iOS: path.join(repoRoot, 'ui/ios/Sources/Views/EmailReaderCSS.swift'),
  Android: path.join(repoRoot, 'ui/android/app/src/main/java/com/inbox2/app/ui/components/EmailReaderCss.kt'),
};

describe('reader scale-to-fit', () => {
  for (const [platform, file] of Object.entries(READER_CSS)) {
    const src = readFileSync(file, 'utf8');
    it(`${platform} defines the scale-to-fit pass`, () => {
      expect(src).toContain('window.__fitEmail');
      expect(src).toContain('scale(');
    });
    // The fit pass must measure overflow at the natural column width via scrollWidth.
    // It must NOT force `width: max-content` to measure — that unwraps flowing prose /
    // a plain-text `pre-wrap` body onto one line, reporting a giant "natural width" and
    // shrinking ordinary emails to an unreadable strip (the prose scale-down regression).
    it(`${platform} measures overflow, not max-content width`, () => {
      expect(src).toContain('scrollWidth');
      expect(src).not.toMatch(/width\s*=\s*'max-content'/);
    });
    // Height backstop: forces html/body height:auto so templates that set
    // height:100% (PayPal receipts, MJML) can't clamp the measured document height
    // to the WebView frame and collapse the body to a sliver. Mirrors the desktop
    // iframe's FRAME_FIT_CSS. Must exist on both platforms.
    it(`${platform} defines the height:100% collapse backstop`, () => {
      expect(src).toContain('height:auto!important');
    });
  }
});
