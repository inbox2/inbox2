// Command-palette data model: sections, recents and filtering.
// Split from the component so it stays plain, testable JS (and so React Fast
// Refresh keeps working — a component file may only export components).
import { fuzzyMatch } from '../../lib/fuzzy';

// Sections, in the order they appear when the palette opens unfiltered.
export const GROUP = { RECENT: 'Recent', GO: 'Navigate', ACTION: 'Actions', VIEW: 'View', APP: 'Application' };
const GROUP_ORDER = [GROUP.RECENT, GROUP.GO, GROUP.ACTION, GROUP.VIEW, GROUP.APP];

// Most-recently-run command ids, newest first — the palette's only persisted state.
const RECENT_KEY = 'palette:recent';
export const RECENT_LIMIT = 4;

export function readRecent() {
  try {
    const raw = JSON.parse(localStorage.getItem(RECENT_KEY));
    return Array.isArray(raw) ? raw.filter(id => typeof id === 'string') : [];
  } catch {
    return []; // private mode / corrupt value — recents are a nicety, never a hard failure
  }
}

export function writeRecent(ids) {
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(ids.slice(0, RECENT_LIMIT)));
  } catch { /* storage full or blocked — ignore */ }
}

/**
 * Filtered, grouped, keyboard-indexed sections.
 *   - No query: the natural groups, with the recents pinned on top.
 *   - Query: one flat list ranked by fuzzy score (recency breaks ties), with the
 *     matched characters marked for highlighting. A command also matches on its
 *     `keywords` (synonyms the label doesn't contain — "dark" for "Switch to
 *     light mode"), ranked below every real label match and never highlighted.
 *   - Query with no hits: the `fallback` command, if one was given, so the
 *     palette offers to search for what was typed instead of dead-ending.
 * Every item carries `index`, its position in the flattened list, so arrow keys,
 * `aria-activedescendant` and scroll-into-view all speak the same coordinate.
 */
// Label match wins; a keyword ("alias") match still counts but ranks below every
// label match and carries no highlight positions — the query isn't in the label.
const ALIAS_PENALTY = 20;

function matchCommand(query, cmd) {
  const onLabel = fuzzyMatch(query, cmd.label);
  if (onLabel) return onLabel;
  const onKeywords = cmd.keywords && fuzzyMatch(query, cmd.keywords);
  return onKeywords ? { score: onKeywords.score - ALIAS_PENALTY, indices: [] } : null;
}

export function buildSections(commands, query, recent, fallback = null) {
  const rank = (id) => {
    const i = recent.indexOf(id);
    return i === -1 ? recent.length : i;
  };
  let sections;

  if (query.trim()) {
    const hits = commands
      .map(cmd => ({ cmd, match: matchCommand(query, cmd) }))
      .filter(x => x.match)
      .sort((a, b) => b.match.score - a.match.score || rank(a.cmd.id) - rank(b.cmd.id))
      .map(({ cmd, match }) => ({ ...cmd, indices: match.indices }));
    sections = [{ title: null, items: hits.length || !fallback ? hits : [fallback] }];
  } else {
    const byId = new Map(commands.map(c => [c.id, c]));
    const recentItems = recent.map(id => byId.get(id)).filter(Boolean);
    const recentIds = new Set(recentItems.map(c => c.id));
    sections = GROUP_ORDER.map(title => ({
      title,
      items: title === GROUP.RECENT
        ? recentItems
        : commands.filter(c => c.group === title && !recentIds.has(c.id)),
    }));
  }

  let index = 0;
  return sections
    .filter(s => s.items.length)
    .map(s => ({ ...s, items: s.items.map(item => ({ ...item, index: index++ })) }));
}

