/**
 * "Did you mean …?" for local-channel search.
 *
 * The MX/API half of search gets its suggestion from Postgres (pg_trgm, see
 * SearchController#closest_term). Local channels never touch the API, so the
 * same job is done here against the SQLite FTS5 index: `messages_vocab` is an
 * fts5vocab view over messages_fts holding every indexed term with its document
 * count — a spell-check dictionary made of the user's own mail, already built.
 *
 * Candidates are edit-distance ranked in JS: SQLite's editdist3 lives in
 * spellfix1, which isn't compiled into the bundled build.
 */

// Unsegmented scripts have no word boundaries to typo — same carve-out the
// server search makes for the CJK substring path.
const UNSEGMENTED_SCRIPT = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}]/u;
const WORD = /[\p{L}\p{N}]{3,}/gu;
const MAX_WORDS = 4;

/**
 * Levenshtein distance, abandoned once every cell of a row exceeds `max`.
 * Returns max + 1 for anything further apart than that.
 */
export function levenshtein(a, b, max) {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      row[j] = Math.min(row[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
      if (row[j] < best) best = row[j];
    }
    if (best > max) return max + 1;
    prev = row;
  }
  return prev[b.length];
}

// One edit for short words, two for longer ones: at distance 2 a 5-letter word
// is a different word ("email" → "small"), a 9-letter one usually isn't.
const maxDistance = (word) => (word.length <= 5 ? 1 : 2);

/**
 * Closest candidate to `word`, or null. Ties break on document count, so the
 * correction is the term the user is most likely to have meant.
 * @param {{term: string, doc: number}[]} candidates
 */
export function pickTerm(word, candidates) {
  const max = maxDistance(word);
  let best = null;
  let bestDist = max + 1;
  for (const { term, doc } of candidates) {
    if (term === word) return null; // the word is spelled fine — nothing to suggest
    const dist = levenshtein(word, term, max);
    if (dist > max) continue;
    if (dist < bestDist || (dist === bestDist && doc > (best?.doc ?? 0))) {
      best = { term, doc };
      bestDist = dist;
    }
  }
  return best?.term ?? null;
}

/**
 * Candidate terms sharing `word`'s first character and near its length.
 *
 * This was a two-character prefix, which is wrong for the most ordinary typo
 * there is: drop a letter ("hssain") and every following character shifts, so
 * "hussain" — 1104 documents away in the index — was never a candidate. One
 * character still keeps it a short range scan (~3.5k terms / 22KB on a 1.6GB
 * store) rather than a 109k-term sweep.
 *
 * ponytail: a typo in the FIRST character still gets no suggestion, since the
 * range scan is anchored there. Fixing that means scanning the whole
 * length-bounded vocabulary; do it only if those turn out to matter.
 */
async function candidates(db, word) {
  const first = String.fromCodePoint(word.codePointAt(0));
  const next = String.fromCodePoint(word.codePointAt(0) + 1);
  return db.select(
    `SELECT term, doc FROM messages_vocab
     WHERE term >= ?1 AND term < ?2 AND length(term) BETWEEN ?3 AND ?4
     ORDER BY doc DESC LIMIT 2000`,
    [first, next, word.length - 2, word.length + 2]
  );
}

/**
 * The query with each mistyped word swapped for its nearest neighbour in the
 * local index, or null when nothing is close enough to suggest.
 */
export async function suggestLocalQuery(db, query) {
  if (UNSEGMENTED_SCRIPT.test(query)) return null;
  const words = [...new Set((query.toLowerCase().match(WORD) || []).slice(0, MAX_WORDS))];
  if (!words.length) return null;

  let suggestion = query;
  for (const word of words) {
    const better = pickTerm(word, await candidates(db, word));
    if (better) {
      suggestion = suggestion.replace(
        new RegExp(`(?<![\\p{L}\\p{N}])${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\p{L}\\p{N}])`, 'iu'),
        better
      );
    }
  }
  return suggestion === query ? null : suggestion;
}
