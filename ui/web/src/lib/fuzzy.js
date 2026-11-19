// Subsequence ("fuzzy") matching for command-palette style filtering:
// "gtc" matches "Go to Calendar", "sett" matches "Settings".
//
// Greedy left-to-right is complete for subsequence existence — if the greedy
// scan fails, no match exists — so the only approximation is the *ranking*.
// ponytail: no scoring library; swap in fzf-style scoring if ranking ever feels wrong.

const WORD_BOUNDARY = /[\s\-_/.:]/;

/**
 * @returns {{score:number, indices:number[]}|null} — null when `text` doesn't
 * contain `query` as a subsequence. Higher score = better match. An empty
 * query matches everything with score 0.
 */
export function fuzzyMatch(query, text) {
  const q = query.trim().toLowerCase();
  if (!q) return { score: 0, indices: [] };

  const haystack = text.toLowerCase();
  const indices = [];
  let score = 0;
  let from = 0;
  let prev = -2;

  for (const ch of q) {
    if (ch === ' ') continue; // spaces only separate terms
    const at = haystack.indexOf(ch, from);
    if (at === -1) return null;

    if (at === prev + 1) score += 8;                            // consecutive run
    if (at === 0) score += 12;                                  // start of label
    else if (WORD_BOUNDARY.test(text[at - 1])) score += 10;     // start of a word
    score -= Math.min(at - from, 4);                            // capped gap penalty

    indices.push(at);
    prev = at;
    from = at + 1;
  }
  return { score, indices };
}

/** Split `text` into [{ text, hit }] runs for highlighting matched characters. */
export function highlightRuns(text, indices) {
  if (!indices?.length) return [{ text, hit: false }];
  const hits = new Set(indices);
  const runs = [];
  for (let i = 0; i < text.length; i++) {
    const hit = hits.has(i);
    const last = runs[runs.length - 1];
    if (last && last.hit === hit) last.text += text[i];
    else runs.push({ text: text[i], hit });
  }
  return runs;
}
