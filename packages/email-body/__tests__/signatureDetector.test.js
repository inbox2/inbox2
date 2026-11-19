// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { detectSignatures } from '../src/signatureDetector.js';

describe('detectSignatures', () => {
  it('wraps a gmail_signature container in data-signature-block', () => {
    const html = '<div>Body of the email here.</div><div class="gmail_signature">Jane Doe<br>Acme</div>';
    const { content, hasSignature } = detectSignatures(html);
    expect(hasSignature).toBe(true);
    expect(content).toContain('data-signature-block');
  });

  it('detects the "-- " RFC 3676 delimiter signature', () => {
    const html = 'Hello there, here is the body.<br>--<br>Jane Doe<br>Acme Inc';
    expect(detectSignatures(html).hasSignature).toBe(true);
  });

  it('detects a contact-block signature without a delimiter', () => {
    const html =
      'Thanks for your help.<br><br>' +
      'Stephanie Sever<br>' +
      'EnronOnline<br>' +
      'Phone: 713-853-6460';
    expect(detectSignatures(html).hasSignature).toBe(true);
  });

  it('returns hasSignature=false for a plain body', () => {
    expect(detectSignatures('<div>Just text, no sign-off at all.</div>').hasSignature).toBe(false);
  });
});
