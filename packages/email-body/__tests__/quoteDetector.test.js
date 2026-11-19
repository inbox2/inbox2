// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { detectQuotes } from '../src/quoteDetector.js';

describe('detectQuotes', () => {
  it('wraps a Gmail quote container in data-quoted-block', () => {
    const html =
      '<div>My reply</div>' +
      '<div class="gmail_quote">On Mon, John wrote:<blockquote>old</blockquote></div>';
    const { content, hasQuote } = detectQuotes(html);
    expect(hasQuote).toBe(true);
    expect(content).toContain('data-quoted-block');
  });

  it('wraps an Apple Mail / Thunderbird cite blockquote', () => {
    const html = '<div>Reply</div><blockquote type="cite">quoted original</blockquote>';
    const { hasQuote, content } = detectQuotes(html);
    expect(hasQuote).toBe(true);
    expect(content).toContain('data-quoted-block');
  });

  it('detects a line-based "On … wrote:" attribution', () => {
    const html =
      'Thanks for that.<br>' +
      'On Mon, Jan 1, 2024 at 10:00 AM John Doe wrote:<br>' +
      'the original message text';
    expect(detectQuotes(html).hasQuote).toBe(true);
  });

  it('detects an unmarked Outlook "From: / Sent: / Subject:" header block', () => {
    const html =
      '<div class="WordSection1">' +
      '<p>Ticket 556 opened for the same.</p>' +
      '<div style="border-top:solid #E1E1E1 1.0pt">' +
      '<p><b>From:</b> Waseem Sadiq [mailto:waseem@tuli.com]<br>' +
      '<b>Sent:</b> Monday, 29 September 2025 4:32 PM<br>' +
      '<b>To:</b> Chadi Samir Richani<br>' +
      '<b>Subject:</b> Re: VAT Tax Group Update</p></div>' +
      '<p>Not a problem, we will handle it</p></div>';
    const { content, hasQuote } = detectQuotes(html);
    expect(hasQuote).toBe(true);
    expect(content).toContain('data-quoted-block');
    // the reply above the header stays outside the collapsed block
    const body = new DOMParser().parseFromString(content, 'text/html').body;
    body.querySelectorAll('[data-quoted-block]').forEach((n) => n.remove());
    expect(body.textContent).toContain('Ticket 556');
    expect(body.textContent).not.toContain('Not a problem');
  });

  it('collapses at an Outlook header block even when a blockquote sits deeper in the quote', () => {
    const html =
      '<div class="WordSection1"><p>Groet, Bart</p>' +
      '<div style="border-top:solid #E1E1E1 1.0pt">' +
      '<p><b>From:</b> waseem@tuli.com<br><b>Sent:</b> Wednesday<br>' +
      '<b>To:</b> Bart<br><b>Subject:</b> Re: AI</p></div>' +
      '<p>Dag Walter en Bart,</p>' +
      '<div><p>On 10/8/2026, Walter wrote:</p><blockquote>Dat is prima</blockquote></div></div>';
    const { content } = detectQuotes(html);
    const body = new DOMParser().parseFromString(content, 'text/html').body;
    body.querySelectorAll('[data-quoted-block]').forEach((n) => n.remove());
    expect(body.textContent).toContain('Groet, Bart');
    expect(body.textContent).not.toContain('Dag Walter');
  });

  it('detects a header block spread over <br> lines', () => {
    const html =
      'Thanks.<br><br>' +
      'From: Waseem Sadiq &lt;waseem@tuli.com&gt;<br>' +
      'Sent: Monday, 29 September 2025<br>' +
      'To: someone<br>' +
      'Subject: Re: hello<br>' +
      'original text';
    expect(detectQuotes(html).hasQuote).toBe(true);
  });

  it('returns hasQuote=false for a plain message', () => {
    expect(detectQuotes('<div>Just a normal message with no quote.</div>').hasQuote).toBe(false);
  });
});
