// @vitest-environment jsdom
//
// The unified inbox no longer re-derives the badge from the list it's holding
// (that list is one page per channel, so the number meant something different on
// every screen). It moves the badge by a delta when you act, and
// useChannelUnreadCounts recounts the truth. These cover the delta half.
//
// No @testing-library in this repo, so the hook runs in a bare React root
// (same pattern as useChannelUnreadCounts.test.js).
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';

vi.mock('../../lib/tauri', () => ({ isTauri: () => false, getOS: () => 'macos' }));
vi.mock('../../lib/db.js', () => ({ getDb: async () => { throw new Error('not used'); } }));
vi.mock('../../lib/log', () => ({ default: { warn: () => {}, info: () => {}, error: () => {} } }));
vi.mock('../useSyncRefresh', () => ({ default: () => {} }));
vi.mock('../useMailRefresh', () => ({ default: () => {} }));
vi.mock('../useRefetchOnFocus', () => ({ default: () => {} }));

const getConversations = vi.fn();
const bulkConversations = vi.fn(async () => ({}));
vi.mock('../../lib/localFirstApi', () => ({
  default: {
    getConversations: (...args) => getConversations(...args),
    bulkConversations: (...args) => bulkConversations(...args),
  },
}));

const { default: useUnreadStore } = await import('../../stores/unreadStore');
const { default: useUnifiedInbox } = await import('../useUnifiedInbox');
const { CONV_ACTION } = await import('../../lib/conversationActions');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const ACCOUNTS = [
  { key: 'org_a', provider_type: 'inbox2', orgSlug: 'a-org' },
  { key: 'org_b', provider_type: 'inbox2', orgSlug: 'b-org' },
];

const flush = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });

const roots = [];
function mount() {
  const held = {};
  const Probe = () => { held.current = useUnifiedInbox(ACCOUNTS, null, null); return null; };
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe)));
  roots.push(root);
  return held;
}

beforeEach(() => {
  getConversations.mockReset();
  bulkConversations.mockClear();
  // The recount that would normally seed these lives in useChannelUnreadCounts;
  // here the badge starts from a known truth and the actions move it.
  useUnreadStore.setState({ byChannel: { org_a: 1, org_b: 1 }, total: 2, mutations: 0 });
  getConversations.mockImplementation(async (orgId) => ({
    conversations: orgId === 'a-org'
      ? [{ id: 'conv_a1', read: false, updated_at: '2026-08-20T10:00:00Z' }]
      : [
        { id: 'conv_b1', read: false, updated_at: '2026-08-20T09:00:00Z' },
        { id: 'conv_b2', read: true, updated_at: '2026-08-20T08:00:00Z' },
      ],
  }));
});

afterEach(() => {
  act(() => { while (roots.length) roots.pop().unmount(); });
});

describe('useUnifiedInbox column paging', () => {
  const PAGE_SIZE = 50; // COLUMN_PAGE_SIZE in the hook
  const rows = (org, from, count) => ({
    conversations: Array.from({ length: count }, (_, i) => ({
      id: `${org}${from + i}`, read: true, updated_at: `2026-08-${20 - ((from + i) % 19)}T10:00:00Z`,
    })),
  });
  const columnOf = (held, key) => held.current.allConversations.filter(c => c.accountKey === key);

  // org_a has three pages of mail; org_b fits in one. The triaged query (tags[])
  // is answered separately — nothing triaged unless a test says so.
  const paged = (aPage) => async (orgId, params) => (
    params.tags ? { conversations: [] }
      : orgId === 'a-org' ? rows('a', ((params.page || 1) - 1) * PAGE_SIZE, aPage(params.page || 1))
        : rows('b', 0, 2)
  );

  it('pages one column without touching its neighbours', async () => {
    getConversations.mockImplementation(paged(() => PAGE_SIZE));
    const held = mount();
    await flush();
    expect(columnOf(held, 'org_a')).toHaveLength(PAGE_SIZE);

    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    await flush();

    expect(columnOf(held, 'org_a')).toHaveLength(PAGE_SIZE * 2);
    expect(columnOf(held, 'org_b')).toHaveLength(2); // untouched
    expect(getConversations).toHaveBeenLastCalledWith('a-org',
      expect.objectContaining({ page: 2, per_page: PAGE_SIZE }));
  });

  it('stops a column at its short page and never asks again', async () => {
    getConversations.mockImplementation(paged(p => (p === 1 ? PAGE_SIZE : 3)));
    const held = mount();
    await flush();

    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    await flush();
    expect(columnOf(held, 'org_a')).toHaveLength(PAGE_SIZE + 3);

    const calls = getConversations.mock.calls.length;
    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    expect(getConversations.mock.calls.length).toBe(calls);
  });

  it('never asks a column that fit in one page', async () => {
    getConversations.mockImplementation(paged(() => PAGE_SIZE));
    const held = mount();
    await flush();
    const calls = getConversations.mock.calls.length;

    await act(async () => { await held.current.loadMoreColumn('org_b'); });
    expect(getConversations.mock.calls.length).toBe(calls);
  });

  it('keeps the pages a column scrolled in when the inbox refreshes', async () => {
    getConversations.mockImplementation(paged(() => PAGE_SIZE));
    const held = mount();
    await flush();
    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    await flush();
    expect(columnOf(held, 'org_a')).toHaveLength(PAGE_SIZE * 2);

    // Sync / new mail / focus all refetch page 1 of every column.
    await act(async () => { await held.current.refetch(); });
    await flush();
    expect(columnOf(held, 'org_a')).toHaveLength(PAGE_SIZE * 2);

    // …and the column carries on from where it was.
    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    await flush();
    expect(getConversations).toHaveBeenLastCalledWith('a-org', expect.objectContaining({ page: 3 }));
  });

  it('loads the triaged threads even when they sit past the last loaded page', async () => {
    // The Eisenhower matrix draws the triaged threads out of the loaded set, and
    // a thread triaged weeks ago is far below the first page — so it gets its
    // own query instead of hoping it falls inside one.
    const triaged = {
      conversations: [
        { id: 'old_urgent', read: true, updated_at: '2020-01-01T00:00:00Z', tags: [{ name: 'Urgent' }] },
        { id: 'old_later', read: true, updated_at: '2020-01-02T00:00:00Z', tags: [{ name: 'Later' }] },
      ],
    };
    getConversations.mockImplementation(async (orgId, params) => (
      params.tags ? (orgId === 'a-org' ? triaged : { conversations: [] })
        : orgId === 'a-org' ? rows('a', 0, PAGE_SIZE) : rows('b', 0, 2)
    ));
    const held = mount();
    await flush();

    expect(getConversations).toHaveBeenCalledWith('a-org',
      expect.objectContaining({ tags: ['Urgent', 'Important', 'Later'] }));
    // In the list the matrix reads…
    const all = held.current.allConversations.map(c => c.id);
    expect(all).toContain('old_urgent');
    expect(all).toContain('old_later');
    expect(held.current.allConversations.filter(c => c.triaged)).toHaveLength(2);
    // …and out of the stream, which shows the untriaged threads.
    const stream = held.current.conversations.map(c => c.id);
    expect(stream).not.toContain('old_urgent');
    expect(stream).toHaveLength(PAGE_SIZE + 2); // org_a's page + org_b's two
  });

  it('drops rows a moving list repeats across pages', async () => {
    getConversations.mockImplementation(async (orgId, params) => (
      params.tags ? { conversations: [] }
        : orgId === 'a-org'
          ? rows('a', ((params.page || 1) - 1) * PAGE_SIZE - ((params.page || 1) > 1 ? 1 : 0), PAGE_SIZE)
          : rows('b', 0, 2)
    ));
    const held = mount();
    await flush();
    await act(async () => { await held.current.loadMoreColumn('org_a'); });
    await flush();

    const ids = columnOf(held, 'org_a').map(c => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toHaveLength(PAGE_SIZE * 2 - 1);
  });
});

describe('useUnifiedInbox badge', () => {
  const act_ = async (held, ...args) => {
    await act(async () => { await held.current.performConversationAction(...args); });
    await flush();
  };

  it('clears the tab badge when a channel\'s last unread thread is spammed', async () => {
    const held = mount();
    await flush();

    await act_(held, 'conv_a1', 'org_a', CONV_ACTION.SPAM);

    expect(useUnreadStore.getState().byChannel.org_a).toBe(0);
    expect(useUnreadStore.getState().byChannel.org_b).toBe(1);
    expect(useUnreadStore.getState().total).toBe(1);
  });

  it('leaves the badge alone when the filed thread was already read', async () => {
    const held = mount();
    await flush();

    await act_(held, 'conv_b2', 'org_b', CONV_ACTION.TRASH);

    expect(useUnreadStore.getState().byChannel.org_b).toBe(1);
  });

  it('moves the badge on mark read/unread too', async () => {
    const held = mount();
    await flush();

    await act_(held, 'conv_b1', 'org_b', CONV_ACTION.MARK_READ);
    expect(useUnreadStore.getState().byChannel.org_b).toBe(0);

    await act_(held, 'conv_b1', 'org_b', CONV_ACTION.MARK_UNREAD);
    expect(useUnreadStore.getState().byChannel.org_b).toBe(1);
  });

  it('puts the count back when the removal is undone', async () => {
    const held = mount();
    await flush();

    await act_(held, 'conv_a1', 'org_a', CONV_ACTION.SPAM);
    expect(useUnreadStore.getState().byChannel.org_a).toBe(0);

    const { default: useUndoStore } = await import('../../stores/undoStore');
    await act(async () => { await useUndoStore.getState().undo(); });
    await flush();

    expect(useUnreadStore.getState().byChannel.org_a).toBe(1);
  });
});
