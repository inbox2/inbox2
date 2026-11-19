import { describe, it, expect } from 'vitest';
import {
  squarify, changeBucket, weightedChange, tzOffsetMinutes, relativeOffset,
  workingSpans, sharedWindow, rainSummary, mergeConfig, tickerLabel, weatherIcon, dayPhase,
} from '../touchStrip';

// A fixed instant in summer time: 12:00 UTC on 2026-07-01.
const JULY = new Date(Date.UTC(2026, 6, 1, 12, 0));

describe('squarify', () => {
  it('tiles the whole box, areas proportional to value', () => {
    const cells = squarify([{ id: 'a', value: 6 }, { id: 'b', value: 3 }, { id: 'c', value: 1 }], 200, 30);
    const area = cells.reduce((s, c) => s + c.w * c.h, 0);
    expect(area).toBeCloseTo(6000);
    const a = cells.find((c) => c.id === 'a');
    expect(a.w * a.h).toBeCloseTo(3600);
    for (const c of cells) {
      expect(c.x + c.w).toBeLessThanOrEqual(200.0001);
      expect(c.y + c.h).toBeLessThanOrEqual(30.0001);
    }
  });

  it('is empty for no weight or no room', () => {
    expect(squarify([], 100, 30)).toEqual([]);
    expect(squarify([{ value: 1 }], 0, 30)).toEqual([]);
  });
});

describe('market helpers', () => {
  it('buckets day change', () => {
    expect(changeBucket(0.01)).toBe('flat');
    expect(changeBucket(0.5)).toBe('up1');
    expect(changeBucket(-1.5)).toBe('down2');
    expect(changeBucket(4)).toBe('up3');
  });

  it('weights the headline change', () => {
    const q = [{ symbol: 'A', change_pct: 2 }, { symbol: 'B', change_pct: -1 }, { symbol: 'C', change_pct: null }];
    expect(weightedChange(q, (s) => (s === 'A' ? 2 : 1))).toBeCloseTo(1);
  });

  it('labels tickers', () => {
    expect(tickerLabel('ASML.AS')).toBe('ASML');
    expect(tickerLabel('BTC-EUR')).toBe('BTC');
    expect(tickerLabel('^AEX')).toBe('AEX');
  });
});

describe('time zones', () => {
  it('knows DST offsets', () => {
    expect(tzOffsetMinutes('Europe/Amsterdam', JULY)).toBe(120);
    expect(tzOffsetMinutes('America/New_York', JULY)).toBe(-240);
    expect(relativeOffset('America/New_York', 'Europe/Amsterdam', JULY)).toBe('−6');
    expect(relativeOffset('Asia/Kolkata', 'Europe/Amsterdam', JULY)).toBe('+3:30');
  });

  it('maps a city working day onto the viewer axis, wrapping midnight', () => {
    expect(workingSpans('America/New_York', 'Europe/Amsterdam', JULY)).toEqual([[900, 1380]]);
    expect(workingSpans('America/Los_Angeles', 'Europe/Amsterdam', JULY)).toEqual([[1080, 1440], [0, 120]]);
  });

  it('knows night from day', () => {
    expect(dayPhase(22 * 60 + 30)).toBe('night');
    expect(dayPhase(5 * 60 + 30)).toBe('night');
    expect(dayPhase(6 * 60 + 30)).toBe('dawn');
    expect(dayPhase(13 * 60)).toBe('day');
    expect(dayPhase(20 * 60)).toBe('dusk');
  });

  it('finds the shared working window', () => {
    expect(sharedWindow(['Europe/Amsterdam', 'America/New_York'], 'Europe/Amsterdam', JULY)).toEqual([900, 1020]);
    expect(sharedWindow(['Europe/Amsterdam', 'Asia/Tokyo', 'America/Los_Angeles'], 'Europe/Amsterdam', JULY)).toBeNull();
  });
});

describe('weather helpers', () => {
  const slot = (t, mm) => ({ time: `2026-09-29T${t}`, mm });

  it('summarises the rain line', () => {
    expect(rainSummary([slot('14:00', 0), slot('14:15', 0)])).toBe('Dry for 1h');
    expect(rainSummary([slot('14:00', 0), slot('14:15', 0.4)])).toBe('Rain from 14:15');
    expect(rainSummary([slot('14:00', 0.6), slot('14:15', 0)])).toBe('Rain until ~14:15');
    expect(rainSummary([])).toBeNull();
  });

  it('picks day/night icons', () => {
    expect(weatherIcon(0, true)).toBe('sun.max.fill');
    expect(weatherIcon(0, false)).toBe('moon.fill');
    expect(weatherIcon(63)).toBe('cloud.rain');
  });
});

describe('mergeConfig', () => {
  it('keeps defaults for unsaved sections and drops unknown widgets', () => {
    const c = mergeConfig({ items: ['stocks', 'bogus'], crypto: null, options: { crypto_currency: 'USD' } });
    expect(c.items).toEqual(['stocks']);
    expect(c.crypto).toEqual(['BTC', 'ETH', 'SOL']);
    expect(c.options).toEqual({ stock_size: 'equal', crypto_currency: 'USD' });
  });
});
