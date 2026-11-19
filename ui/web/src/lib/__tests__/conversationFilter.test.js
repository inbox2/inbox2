import { describe, it, expect } from 'vitest';
import { filterConversations } from '../conversationFilter';

const conv = (over) => ({ id: 'c', subject: '', from_address: '', read: true, ...over });

describe('filterConversations', () => {
  const list = [
    conv({ id: '1', subject: 'Budget review', from_address: 'ada@x.com' }),
    conv({ id: '2', subject: 'Lunch plans', from_address: 'bob@y.com' }),
  ];

  it('returns the list unchanged with no filters', () => {
    expect(filterConversations(list, { labelFilters: new Map(), listFilter: '', activeAccountKey: null }))
      .toHaveLength(2);
  });

  it('text-filters org accounts on subject or sender (case-insensitive)', () => {
    const out = filterConversations(list, { labelFilters: new Map(), listFilter: 'BUDGET', activeAccountKey: null });
    expect(out.map((c) => c.id)).toEqual(['1']);

    const bySender = filterConversations(list, { labelFilters: new Map(), listFilter: 'bob@', activeAccountKey: null });
    expect(bySender.map((c) => c.id)).toEqual(['2']);
  });

  it('does NOT text-filter external accounts (SQL already did)', () => {
    const out = filterConversations(list, { labelFilters: new Map(), listFilter: 'budget', activeAccountKey: 'acct_1' });
    expect(out).toHaveLength(2);
  });
});
