// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { unwrapWrappedHtml } from '../src/unwrapWrappedHtml.js';

function parse(html) {
  return new DOMParser().parseFromString(html, 'text/html');
}

describe('unwrapWrappedHtml', () => {
  it('unwraps a <pre> that wraps a structural HTML email', () => {
    // The ADCB case: a full document wrapped in <pre>, parsed to a <pre> holding
    // tables. Unwrapping must lift the table out so it lays out as normal HTML.
    const doc = parse('<pre><!DOCTYPE html><table width="640"><tr><td><img src="x.png"></td></tr></table></pre>');
    const n = unwrapWrappedHtml(doc.body);
    expect(n).toBe(1);
    expect(doc.body.querySelector('pre')).toBeNull();
    expect(doc.body.querySelector('table')).not.toBeNull();
  });

  it('leaves a genuine preformatted text block alone', () => {
    const doc = parse('<pre>line 1\n  indented line 2\n</pre>');
    const n = unwrapWrappedHtml(doc.body);
    expect(n).toBe(0);
    expect(doc.body.querySelector('pre')).not.toBeNull();
  });

  it('does nothing when there is no <pre>', () => {
    const doc = parse('<table><tr><td>hi</td></tr></table>');
    expect(unwrapWrappedHtml(doc.body)).toBe(0);
  });
});
