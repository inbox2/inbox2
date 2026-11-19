import { describe, it, expect } from 'vitest';
import {
  getQuadrant,
  getConvQuadrant,
  QUADRANTS,
  PRIORITY_URGENT,
  PRIORITY_IMPORTANT,
  PRIORITY_LATER,
} from '../priority';

describe('getQuadrant', () => {
  it('maps the two priority flags to the four quadrants', () => {
    expect(getQuadrant(true, true)).toBe(QUADRANTS.DO_FIRST);
    expect(getQuadrant(true, false)).toBe(QUADRANTS.DELEGATE);
    expect(getQuadrant(false, true)).toBe(QUADRANTS.SCHEDULE);
    // Later has no priority flags — the case that used to collide with untriaged.
    expect(getQuadrant(false, false)).toBe(QUADRANTS.LATER);
  });
});

describe('getConvQuadrant', () => {
  it('returns null for an untriaged conversation', () => {
    expect(getConvQuadrant({})).toBeNull();
    expect(getConvQuadrant({ priority_urgent: 0, priority_important: 0, priority_triaged: 0 })).toBeNull();
    expect(getConvQuadrant({ tags: [] })).toBeNull();
  });

  it('detects flagged quadrants from columns, normalized fields, and tags', () => {
    expect(getConvQuadrant({ priority_urgent: 1, priority_important: 1 })).toBe(QUADRANTS.DO_FIRST);
    expect(getConvQuadrant({ urgent: true })).toBe(QUADRANTS.DELEGATE);
    expect(getConvQuadrant({ important: true })).toBe(QUADRANTS.SCHEDULE);
    expect(getConvQuadrant({ tags: [{ name: PRIORITY_URGENT }, { name: PRIORITY_IMPORTANT }] }))
      .toBe(QUADRANTS.DO_FIRST);
  });

  // Regression: "Later" has no priority flags, so it relies on an explicit
  // marker (Later tag for org accounts, priority_triaged column for external,
  // or the normalized `triaged` field). Without it a Later placement read back
  // as untriaged and vanished from the matrix on refresh.
  it('recognizes "Later" from each persistence marker', () => {
    expect(getConvQuadrant({ tags: [{ name: PRIORITY_LATER }] })).toBe(QUADRANTS.LATER);
    expect(getConvQuadrant({ priority_triaged: 1 })).toBe(QUADRANTS.LATER);
    expect(getConvQuadrant({ triaged: true })).toBe(QUADRANTS.LATER);
  });

  it('does not treat a flagged conversation as Later even when the marker is set', () => {
    // A triaged conv that also has a priority flag belongs to its flagged
    // quadrant, never Later.
    expect(getConvQuadrant({ urgent: true, triaged: true })).toBe(QUADRANTS.DELEGATE);
    expect(getConvQuadrant({ important: true, priority_triaged: 1 })).toBe(QUADRANTS.SCHEDULE);
  });
});
