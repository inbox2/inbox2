// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { processBody } from '../src/index.js';

describe('processBody', () => {
  it('unwraps a <pre>-wrapped HTML document (the iOS/Android path)', () => {
    const html = '<pre><!DOCTYPE html><table><tr><td>Hello</td></tr></table></pre>';
    const out = processBody(html, { block: false });
    expect(out.html).not.toContain('<pre');
    expect(out.html).toContain('<table');
  });

  it('still blocks remote content and reports the count', () => {
    const out = processBody('<img src="https://t.example/x.gif">');
    expect(out.blockedCount).toBeGreaterThan(0);
    // The live src is neutralized to the data: placeholder; the original is
    // stashed on data-blocked-src for the host to restore.
    expect(out.html).toContain('data-blocked-src="https://t.example/x.gif"');
    expect(out.html).toContain('src="data:image/gif;base64,');
  });

  it('leaves a genuine preformatted code block alone', () => {
    const out = processBody('<pre>const a = 1;\nconst b = 2;</pre>', { block: false });
    expect(out.html).toContain('<pre');
  });
});
