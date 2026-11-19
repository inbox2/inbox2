import { describe, it, expect } from 'vitest';
import { levenshtein, pickTerm, suggestLocalQuery } from '../searchSuggest.js';

// Stand-in for the fts5vocab table: returns the rows whose term falls in the
// prefix range the query asks for, like SQLite would.
const fakeDb = (vocab) => ({
  async select(_sql, [from, to, minLen, maxLen]) {
    return vocab
      .filter(v => v.term >= from && v.term < to && v.term.length >= minLen && v.term.length <= maxLen)
      .sort((a, b) => b.doc - a.doc);
  },
});

const VOCAB = [
  { term: 'emirates', doc: 729 },
  { term: 'email', doc: 19643 },
  { term: 'emails', doc: 3691 },
  { term: 'booking', doc: 40 },
  { term: 'hussain', doc: 1104 },
  { term: 'holiday', doc: 88 },
];

describe('levenshtein', () => {
  it('measures edits', () => {
    expect(levenshtein('emirats', 'emirates', 2)).toBe(1);
    expect(levenshtein('kitten', 'sitting', 3)).toBe(3);
    expect(levenshtein('same', 'same', 2)).toBe(0);
  });

  it('bails out past max instead of computing the true distance', () => {
    expect(levenshtein('emirats', 'booking', 2)).toBe(3);
    expect(levenshtein('a', 'abcdefgh', 2)).toBe(3);
  });
});

describe('pickTerm', () => {
  it('breaks ties on document count', () => {
    expect(pickTerm('emals', [{ term: 'emails', doc: 3691 }, { term: 'emile', doc: 276 }])).toBe('emails');
  });

  it('suggests nothing for a correctly spelled word', () => {
    expect(pickTerm('emirates', VOCAB)).toBeNull();
  });

  it('holds a 5-letter word to one edit', () => {
    // "small" is two edits from "email" — a different word, not a typo of it.
    expect(pickTerm('small', [{ term: 'email', doc: 19643 }])).toBeNull();
    expect(pickTerm('smail', [{ term: 'email', doc: 19643 }])).toBe('email');
  });
});

describe('suggestLocalQuery', () => {
  it('corrects a typo to a term in the index', async () => {
    expect(await suggestLocalQuery(fakeDb(VOCAB), 'emirats')).toBe('emirates');
  });

  it('corrects a dropped letter, which shifts every character after it', async () => {
    // Regression: a two-character prefix filter looked for "hs…" and never saw
    // "hussain" at all.
    expect(await suggestLocalQuery(fakeDb(VOCAB), 'hssain')).toBe('hussain');
  });

  it('corrects only the mistyped word', async () => {
    expect(await suggestLocalQuery(fakeDb(VOCAB), 'booking emirats')).toBe('booking emirates');
  });

  it('returns null when the query is already spelled right', async () => {
    expect(await suggestLocalQuery(fakeDb(VOCAB), 'emirates booking')).toBeNull();
  });

  it('returns null when nothing in the index is close', async () => {
    expect(await suggestLocalQuery(fakeDb(VOCAB), 'zzqqxwv')).toBeNull();
  });

  it('skips scripts that have no word boundaries', async () => {
    expect(await suggestLocalQuery(fakeDb(VOCAB), '您的订单')).toBeNull();
  });
});
