// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { blockRemoteContent, PLACEHOLDER } from '../src/blockRemoteContent.js';

function parse(html) {
  return new DOMParser().parseFromString(html, 'text/html');
}

describe('blockRemoteContent', () => {
  it('neutralizes an external img src and stashes the original', () => {
    const doc = parse('<img src="https://tracker.example/x.gif">');
    const count = blockRemoteContent(doc.body);
    const img = doc.body.querySelector('img');
    expect(count).toBeGreaterThan(0);
    expect(img.getAttribute('src')).toBe(PLACEHOLDER);
    expect(img.dataset.blockedSrc).toBe('https://tracker.example/x.gif');
  });

  it('stashes an inline background-image url', () => {
    const doc = parse('<div style="background-image:url(https://t.example/bg.png)">x</div>');
    blockRemoteContent(doc.body);
    const div = doc.body.querySelector('div');
    expect(div.dataset.blockedBg).toContain('https://t.example/bg.png');
  });

  it('keeps the 1x1 GIF placeholder when the img has no dimensions', () => {
    const doc = parse('<img src="https://t.example/x.gif">');
    blockRemoteContent(doc.body);
    expect(doc.body.querySelector('img').getAttribute('src')).toBe(PLACEHOLDER);
  });

  it('uses an aspect-ratio-preserving SVG placeholder when width+height are set', () => {
    // A 600x40 divider under `img{width:100%;height:auto}` must NOT balloon into
    // a 600px square — the placeholder carries the real 15:1 intrinsic ratio.
    const doc = parse('<img src="https://t.example/bar.png" width="600" height="40">');
    blockRemoteContent(doc.body);
    const src = doc.body.querySelector('img').getAttribute('src');
    expect(src).toMatch(/^data:image\/svg\+xml,/);
    expect(decodeURIComponent(src)).toContain('width="600"');
    expect(decodeURIComponent(src)).toContain('height="40"');
  });

  it('collapses a width-only image to a thin line so it cannot balloon', () => {
    // The common case: `width="125"` with height from `img{height:auto}`. A 1x1
    // GIF would become a 125x125 square; the SVG defaults height to 1px.
    const doc = parse('<img src="https://t.example/btn.png" width="125">');
    blockRemoteContent(doc.body);
    const src = decodeURIComponent(doc.body.querySelector('img').getAttribute('src'));
    expect(src).toContain('width="125"');
    expect(src).toContain('height="1"');
  });

  it('falls back to the GIF when the only dimension is a percentage', () => {
    const doc = parse('<img src="https://t.example/x.png" width="100%">');
    blockRemoteContent(doc.body);
    expect(doc.body.querySelector('img').getAttribute('src')).toBe(PLACEHOLDER);
  });

  it('strips srcset so it cannot bypass the block', () => {
    const doc = parse('<img srcset="https://t.example/a.png 1x, https://t.example/b.png 2x">');
    blockRemoteContent(doc.body);
    const img = doc.body.querySelector('img');
    expect(img.hasAttribute('srcset')).toBe(false);
  });

  it('counts nothing for content with no remote references', () => {
    const doc = parse('<p>Plain text, no images.</p>');
    expect(blockRemoteContent(doc.body)).toBe(0);
  });
});
