import { describe, it, expect } from 'vitest';
import { abbrOf, searchZones, shortOffset, wallToInstant, wallParts, offsetMinutes } from '../timeZones';

const JULY = new Date('2026-07-01T12:00:00Z');
const JANUARY = new Date('2026-01-15T12:00:00Z');

describe('abbrOf', () => {
  it('names zones CLDR abbreviates and ones it does not', () => {
    expect(abbrOf('Europe/Amsterdam', JULY)).toBe('CEST');
    expect(abbrOf('Europe/Amsterdam', JANUARY)).toBe('CET');
    expect(abbrOf('America/New_York', JULY)).toBe('EDT');
    expect(abbrOf('Asia/Karachi', JULY)).toBe('PKT');
    expect(abbrOf('Europe/Moscow', JULY)).toBe('MSK');
    expect(abbrOf('Asia/Tokyo', JULY)).toBe('JST');
  });

  it('falls back to the offset for zones with no name', () => {
    expect(abbrOf('Asia/Urumqi', JULY)).toBe(shortOffset('Asia/Urumqi', JULY));
  });
});

describe('wallToInstant', () => {
  it('lands on the requested wall-clock hour', () => {
    for (const tz of ['Europe/Amsterdam', 'Asia/Karachi', 'America/New_York', 'Asia/Kolkata']) {
      for (const h of [0, 9, 23]) {
        expect(wallParts(tz, wallToInstant(tz, 2026, 7, 1, h)).hour).toBe(h);
      }
    }
  });

  it('survives the day the clocks go forward', () => {
    // 2026-03-29: Amsterdam skips 02:00 → 03:00.
    const at = wallToInstant('Europe/Amsterdam', 2026, 3, 29, 9);
    expect(wallParts('Europe/Amsterdam', at).hour).toBe(9);
    expect(offsetMinutes('Europe/Amsterdam', at)).toBe(120);
  });
});

describe('searchZones', () => {
  it('finds a zone by the abbreviation it has in the other half of the year', () => {
    const hits = searchZones('est');
    expect(hits).toContain('America/New_York');
    expect(hits.indexOf('America/New_York')).toBeLessThan(hits.indexOf('Europe/Budapest'));
  });

  it('finds a zone by city name, underscore and all', () => {
    expect(searchZones('new york')).toContain('America/New_York');
    expect(searchZones('karachi')).toEqual(['Asia/Karachi']);
  });
});
