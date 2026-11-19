// @vitest-environment jsdom
//
// The MX list is paginated by the API, and nothing used to ask for page 2 — the
// inbox ended at the first page while the unread badge counted the whole pool.
// These cover the load-more path: it appends, it survives the row repeats that
// offset paging over a moving list produces, and it knows when to stop.
//
// No @testing-library in this repo, so the hook runs in a bare React root
// (same pattern as useChannelUnreadCounts.test.js).
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';

vi.mock('../../lib/tauri', () => ({ isTauri: () => false, getOS: () => 'macos' }));
vi.mock('../../lib/db.js', () => ({ getDb: async () => null }));
vi.mock('../../lib/log', () => ({ default: { warn: () => {}, info: () => {}, error: () => {} } }));
vi.mock('../useSyncRefresh', () => ({ default: () => {} }));
vi.mock('../useMailRefresh', () => ({ default: () => {} }));
vi.mock('../useRefetchOnFocus', () => ({ default: () => {} }));

const getConversations = vi.fn();
vi.mock('../../lib/localFirstApi', () => ({
  default: { getConversations: (...args) => getConversations(...args) },
}));

const { default: useInboxConversations } = await import('../useInboxConversations');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const PAGE_SIZE = 50; // ORG_PAGE_SIZE in the hook
const page = (from, count) => ({
  conversations: Array.from({ length: count }, (_, i) => ({ id: `c${from + i}`, read: true })),
});

const flush = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });

// Hoisted: the query is memoized on these, so a fresh object per render would
// re-run the list effect on every render (as it would in the app if InboxPage
// ever passed an inline view).
const PROPS = {
  activeAccountKey: null,
  activeAccountProvider: null,
  orgId: 'a-org',
  activeView: { kind: 'system', name: 'Inbox' },
  mailboxFilter: null, senderFilter: null, textFilter: '',
  selectedId: null, syncStatus: null, selectedTags: null,
  spaceFilter: null, domainFilter: null,
};

const roots = [];
function mount() {
  const held = {};
  const Probe = ({ props }) => {
    held.current = useInboxConversations(props);
    return null;
  };
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe, { props: PROPS })));
  roots.push(root);
  held.rerender = (props) => act(() => root.render(createElement(Probe, { props })));
  return held;
}

beforeEach(() => getConversations.mockReset());
afterEach(() => {
  act(() => { while (roots.length) roots.pop().unmount(); });
});

describe('useInboxConversations MX paging', () => {
  it('asks for a full page and reports there is more behind it', async () => {
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    const held = mount();
    await flush();

    expect(getConversations).toHaveBeenCalledWith('a-org',
      expect.objectContaining({ per_page: PAGE_SIZE, status: 'open' }));
    expect(held.current.conversations).toHaveLength(PAGE_SIZE);
    expect(held.current.hasMoreConversations).toBe(true);
  });

  it('appends the next page on demand, same query, page 2', async () => {
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    const held = mount();
    await flush();

    getConversations.mockResolvedValue({ ...page(PAGE_SIZE, PAGE_SIZE), meta: { total: 137 } });
    await act(async () => { await held.current.loadMoreConversations(); });
    await flush();

    expect(getConversations).toHaveBeenLastCalledWith('a-org',
      expect.objectContaining({ page: 2, per_page: PAGE_SIZE, status: 'open' }));
    expect(held.current.conversations).toHaveLength(PAGE_SIZE * 2);
    expect(held.current.conversations[PAGE_SIZE].id).toBe(`c${PAGE_SIZE}`);
  });

  it('drops rows that repeat across pages (the list moves under the offset)', async () => {
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    const held = mount();
    await flush();

    // New mail pushed everything down by one, so page 2 starts with a row the
    // first page already showed.
    getConversations.mockResolvedValue({ ...page(PAGE_SIZE - 1, PAGE_SIZE), meta: { total: 137 } });
    await act(async () => { await held.current.loadMoreConversations(); });
    await flush();

    const ids = held.current.conversations.map(c => c.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(held.current.conversations).toHaveLength(PAGE_SIZE * 2 - 1);
  });

  it('stops at a short page instead of asking forever', async () => {
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    const held = mount();
    await flush();

    // Everything left is a repeat: the loaded length can't reach `total`, so
    // only the short page can end the scroll.
    getConversations.mockResolvedValue({ ...page(0, 3), meta: { total: 137 } });
    await act(async () => { await held.current.loadMoreConversations(); });
    await flush();

    expect(held.current.hasMoreConversations).toBe(false);
    const calls = getConversations.mock.calls.length;
    await act(async () => { await held.current.loadMoreConversations(); });
    expect(getConversations.mock.calls.length).toBe(calls);
  });

  it('does not page a folder that fits in one page', async () => {
    getConversations.mockResolvedValue({ ...page(0, 7), meta: { total: 7 } });
    const held = mount();
    await flush();
    expect(held.current.hasMoreConversations).toBe(false);
  });

  // Load page 1 + page 2 and hand back the probe, scrolled two pages deep.
  const mountTwoPagesDeep = async () => {
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    const held = mount();
    await flush();
    getConversations.mockResolvedValue({ ...page(PAGE_SIZE, PAGE_SIZE), meta: { total: 137 } });
    await act(async () => { await held.current.loadMoreConversations(); });
    await flush();
    expect(held.current.conversations).toHaveLength(PAGE_SIZE * 2);
    return held;
  };

  it('keeps the pages you scrolled in when the folder reloads itself', async () => {
    const held = await mountTwoPagesDeep();

    // New mail / focus / the 30s failsafe all refetch page 1. Replacing the list
    // with it would throw away page 2 and jump the user back to the top.
    getConversations.mockResolvedValue({ ...page(0, PAGE_SIZE), meta: { total: 137 } });
    await act(async () => { held.current.retry(); });
    await flush();
    expect(held.current.conversations).toHaveLength(PAGE_SIZE * 2);

    // And the scroll continues from where it was, not from page 2 again.
    getConversations.mockResolvedValue({ ...page(PAGE_SIZE * 2, PAGE_SIZE), meta: { total: 137 } });
    await act(async () => { await held.current.loadMoreConversations(); });
    await flush();
    expect(getConversations).toHaveBeenLastCalledWith('a-org', expect.objectContaining({ page: 3 }));
  });

  it('starts over at the top when the query changes', async () => {
    const held = await mountTwoPagesDeep();

    // Switching folders is a different query — its first page replaces the list.
    getConversations.mockResolvedValue({ ...page(500, 4), meta: { total: 4 } });
    await act(async () => {
      held.rerender({ ...PROPS, activeView: { kind: 'system', name: 'Sent', filters: [{ field: 'direction', value: 'outbound' }] } });
    });
    await flush();
    expect(held.current.conversations).toHaveLength(4);
    expect(held.current.hasMoreConversations).toBe(false);
  });
});
