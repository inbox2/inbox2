import { describe, it, expect } from 'vitest';
import { monogram, initialsColor, initialsDataUri } from '../initialsIcon';

// The monogram is the only thing telling one MX domain tab from another, so a
// TLD leaking into it is a real collision: every ".com" domain used to end in
// the same letter. "acme.com" → "AC" hid the bug, because its C comes from "com".

describe('monogram', () => {
  it('ignores the TLD on a domain', () => {
    expect(monogram('brightfold.com')).toBe('BR');
    expect(monogram('widgets.co')).toBe('WI');
  });

  it('still reads correctly for the case that masked the bug', () => {
    expect(monogram('acme.com')).toBe('AC');
  });

  it('does not collide across domains sharing a TLD', () => {
    const seen = ['brightfold.com', 'bigcorp.com', 'bluesky.com'].map(monogram);
    expect(new Set(seen).size).toBe(3);
  });

  it('peels multi-part suffixes down to the registrable label', () => {
    expect(monogram('mail.brightfold.co.uk')).toBe('BR');
  });

  it('uses the domain of an address, not the local part', () => {
    expect(monogram('sam@brightfold.com')).toBe('BR');
  });

  it('keeps two-token initials for display names', () => {
    expect(monogram('Acme Corp')).toBe('AC');
    expect(monogram('new-business')).toBe('NB');
  });

  it('handles a single bare token', () => {
    expect(monogram('support')).toBe('SU');
  });

  it('never returns empty for junk input', () => {
    for (const v of ['', null, undefined, '   ']) {
      expect(monogram(v)).toBe('?');
    }
  });
});

describe('initialsDataUri', () => {
  it('is deterministic for the same name', () => {
    expect(initialsDataUri('brightfold.com')).toBe(initialsDataUri('brightfold.com'));
    expect(initialsColor('brightfold.com')).toEqual(initialsColor('brightfold.com'));
  });

  it('carries the brand ring by default, so an MX domain reads as MX', () => {
    const svg = decodeURIComponent(initialsDataUri('brightfold.com'));
    expect(svg).toContain('linearGradient');
    expect(svg).toContain('stroke="url(#r)"');
  });

  it('can be rendered without the ring', () => {
    const svg = decodeURIComponent(initialsDataUri('brightfold.com', { ring: false }));
    expect(svg).not.toContain('linearGradient');
  });

  it('produces a usable image data-URI', () => {
    expect(initialsDataUri('brightfold.com')).toMatch(/^data:image\/svg\+xml,/);
  });
});
