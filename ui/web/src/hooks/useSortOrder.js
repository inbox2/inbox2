import { useState, useCallback, useMemo } from 'react';
import { INBOX_SORT_ORDER } from '../lib/storageKeys';

const SORT_LABELS = { newest: 'Newest', oldest: 'Oldest', unread: 'Unread' };

// Conversation-list sort order, persisted to localStorage. Returns the current
// order, the dropdown items + short label for the toolbar, and a
// `sortConversations(list)` that returns a new sorted array.
export default function useSortOrder() {
  const [sortOrder, setSortOrder] = useState(() => localStorage.getItem(INBOX_SORT_ORDER) || 'newest');

  const setSort = useCallback((order) => {
    setSortOrder(order);
    localStorage.setItem(INBOX_SORT_ORDER, order);
  }, []);

  const sortMenuItems = useMemo(() => [
    { value: 'newest', label: 'Newest first', icon: 'arrow.down', onSelect: () => setSort('newest') },
    { value: 'oldest', label: 'Oldest first', icon: 'arrow.up', onSelect: () => setSort('oldest') },
    { value: 'unread', label: 'Unread first', icon: 'circle.fill', onSelect: () => setSort('unread') },
  ], [setSort]);

  const sortConversations = useCallback((list) =>
    [...list].sort((a, b) => {
      const da = new Date(a.updated_at);
      const db = new Date(b.updated_at);
      switch (sortOrder) {
        case 'oldest': return da - db;
        case 'unread': return (b.read ? 0 : 1) - (a.read ? 0 : 1) || db - da;
        default: return db - da;
      }
    }), [sortOrder]);

  return { sortOrder, sortMenuItems, sortLabel: SORT_LABELS[sortOrder], sortConversations };
}
