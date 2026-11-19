import { getConvQuadrant } from './priority';

// Narrow a conversation list by the active triage-label overlay and the Filter
// field. Pure so it can be unit-tested without a renderer.
//
// External accounts already filter `listFilter` at the SQL layer (whole folder,
// from/to/subject), so re-applying it client-side would wrongly drop
// to_address-only matches — text narrowing is therefore applied only for org
// accounts (activeAccountKey falsy).
export function filterConversations(conversations, { labelFilters, listFilter, activeAccountKey }) {
  let result = conversations;

  if (labelFilters && labelFilters.size > 0) {
    const activeQuadrants = new Set(labelFilters.values());
    result = result.filter((c) => activeQuadrants.has(getConvQuadrant(c)?.key));
  }

  if (listFilter && !activeAccountKey) {
    const needle = listFilter.toLowerCase();
    result = result.filter(
      (c) =>
        (c.subject || '').toLowerCase().includes(needle) ||
        (c.from_address || '').toLowerCase().includes(needle),
    );
  }

  return result;
}
