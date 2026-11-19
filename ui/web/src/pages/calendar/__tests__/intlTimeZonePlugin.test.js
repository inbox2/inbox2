import { describe, it, expect } from 'vitest';
import { IntlNamedTimeZone } from '../intlTimeZonePlugin';

describe('IntlNamedTimeZone', () => {
  it('handles DST — Amsterdam is +120 (CEST) in July, +60 (CET) in January', () => {
    const tz = new IntlNamedTimeZone('Europe/Amsterdam');
    expect(tz.offsetForArray([2026, 6, 27, 12, 0, 0])).toBe(120);
    expect(tz.offsetForArray([2026, 0, 15, 12, 0, 0])).toBe(60);
  });

  it('gives fixed offsets for non-DST and negative zones', () => {
    expect(new IntlNamedTimeZone('Asia/Dubai').offsetForArray([2026, 6, 27, 12, 0, 0])).toBe(240);
    expect(new IntlNamedTimeZone('America/New_York').offsetForArray([2026, 6, 27, 12, 0, 0])).toBe(-240);
  });

  it('converts a UTC timestamp to wall-clock array in the zone', () => {
    const tz = new IntlNamedTimeZone('Europe/Amsterdam');
    // 12:00 UTC in July -> 14:00 in Amsterdam
    expect(tz.timestampToArray(Date.UTC(2026, 6, 27, 12, 0, 0))).toEqual([2026, 6, 27, 14, 0, 0, 0]);
  });
});
