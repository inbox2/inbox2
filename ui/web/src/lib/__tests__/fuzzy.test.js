import { describe, it, expect } from 'vitest';
import { fuzzyMatch, highlightRuns } from '../fuzzy';

const best = (query, labels) =>
  labels
    .map(l => ({ l, m: fuzzyMatch(query, l) }))
    .filter(x => x.m)
    .sort((a, b) => b.m.score - a.m.score)
    .map(x => x.l);

describe('fuzzyMatch', () => {
  it('matches initials across words', () => {
    expect(fuzzyMatch('gtc', 'Go to Calendar')).toBeTruthy();
    expect(fuzzyMatch('gtc', 'Compose new message')).toBeNull();
  });

  it('is case-insensitive and matches contiguous substrings', () => {
    expect(fuzzyMatch('SETT', 'Settings')).toBeTruthy();
  });

  it('ranks word-start and contiguous matches above scattered ones', () => {
    expect(best('cal', ['Go to Calendar', 'Resync all channels'])[0]).toBe('Go to Calendar');
    expect(best('set', ['Settings', 'Toggle unread-only filter'])[0]).toBe('Settings');
  });

  it('treats an empty query as a match for everything', () => {
    expect(fuzzyMatch('  ', 'Anything')).toEqual({ score: 0, indices: [] });
  });

  it('reports the matched positions', () => {
    expect(fuzzyMatch('gi', 'Go to Inbox').indices).toEqual([0, 6]);
  });
});

describe('highlightRuns', () => {
  it('splits into hit / non-hit runs that rebuild the label', () => {
    const runs = highlightRuns('Settings', [0, 1, 2]);
    expect(runs).toEqual([{ text: 'Set', hit: true }, { text: 'tings', hit: false }]);
    expect(runs.map(r => r.text).join('')).toBe('Settings');
  });

  it('returns one plain run with no indices', () => {
    expect(highlightRuns('Settings', [])).toEqual([{ text: 'Settings', hit: false }]);
  });
});
