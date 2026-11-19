// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { detectQuotes } from '../src/quoteDetector.js';
import { detectSignatures } from '../src/signatureDetector.js';
import { bodyIsForwardOnly } from '../src/forwardOnly.js';
import { processBody } from '../src/index.js';

// Mark the body the way the pipeline does before measuring emptiness.
const mark = (html) => detectSignatures(detectQuotes(html).content).content;

describe('bodyIsForwardOnly', () => {
  it('true when only a forwarded/quoted block remains (bare forward)', () => {
    const html =
      '<blockquote type="cite">' +
      '<div>From: Alice<br>Subject: Hi<br>the original message</div>' +
      '</blockquote>';
    expect(bodyIsForwardOnly(mark(html))).toBe(true);
  });

  it('false when the forwarder added their own note above the quote', () => {
    const html =
      '<div>Hey, take a look at this.</div>' +
      '<blockquote type="cite"><div>the original message</div></blockquote>';
    expect(bodyIsForwardOnly(mark(html))).toBe(false);
  });

  it('false for a plain message with no quote', () => {
    expect(bodyIsForwardOnly(mark('<div>Just a normal email.</div>'))).toBe(false);
  });

  it('ignores whitespace-only body text outside the quote', () => {
    const html =
      '<div>   </div><br>' +
      '<blockquote type="cite"><div>forwarded body</div></blockquote>';
    expect(bodyIsForwardOnly(mark(html))).toBe(true);
  });
});

describe('processBody quotesOnly flag', () => {
  it('is true for a bare forward', () => {
    const r = processBody('<blockquote type="cite"><div>forwarded body</div></blockquote>');
    expect(r.hasQuote).toBe(true);
    expect(r.quotesOnly).toBe(true);
  });

  it('is false when the user added a note', () => {
    const r = processBody(
      '<div>FYI</div><blockquote type="cite"><div>forwarded body</div></blockquote>',
    );
    expect(r.hasQuote).toBe(true);
    expect(r.quotesOnly).toBe(false);
  });

  it('is false when there is no quote at all', () => {
    const r = processBody('<div>Plain email body.</div>');
    expect(r.quotesOnly).toBe(false);
  });
});
