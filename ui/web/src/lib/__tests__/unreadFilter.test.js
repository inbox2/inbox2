import { describe, it, expect } from 'vitest';
import { filterUnread } from '../unreadFilter';

const convs = [
  { id: 'a', accountKey: 'k1', read: false },
  { id: 'b', accountKey: 'k1', read: true },
  { id: 'c', accountKey: 'k2', read: true },
];

describe('filterUnread', () => {
  it('passes everything through when the filter is off', () => {
    expect(filterUnread(convs, false)).toEqual(convs);
  });

  it('hides read conversations', () => {
    expect(filterUnread(convs, true).map(c => c.id)).toEqual(['a']);
  });

  it('keeps the pinned (open) conversation once it is marked read', () => {
    expect(filterUnread(convs, true, 'b').map(c => c.id)).toEqual(['a', 'b']);
  });

  it('leaves a channel empty once its only unread is read and unpinned', () => {
    const byChannel = k => filterUnread(convs.filter(c => c.accountKey === k), true);
    expect(byChannel('k1').map(c => c.id)).toEqual(['a']);
    expect(byChannel('k2')).toEqual([]);
  });
});
