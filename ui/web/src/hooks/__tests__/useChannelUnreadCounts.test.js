// @vitest-environment jsdom
//
// This hook is the ONLY writer of the truth behind the unread badge, so these
// cover: it counts server-side (not out of a page of conversations), it recounts
// on the same events that refresh the lists, and an in-flight recount can never
// overwrite an optimistic adjust with its pre-action snapshot.
//
// No @testing-library in this repo, so the hook runs in a bare React root
// (same pattern as useColumnSelection.test.js).
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';

vi.mock('../../lib/tauri', () => ({ isTauri: () => false }));
vi.mock('../../lib/db.js', () => ({ getDb: async () => { throw new Error('not used'); } }));
vi.mock('../../lib/log', () => ({ default: { warn: () => {}, info: () => {} } }));

const getUnreadCount = vi.fn();
vi.mock('../../lib/localFirstApi', () => ({
  default: { getUnreadCount: (...args) => getUnreadCount(...args) },
}));

const { default: syncManager } = await import('../../lib/sync-manager');
const { default: useUnreadStore } = await import('../../stores/unreadStore');
const { default: useChannelUnreadCounts } = await import('../useChannelUnreadCounts');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const ACCOUNTS = [{ key: 'org_a', provider_type: 'inbox2' }];
const DOMAIN_TAB = [{ key: 'dom_a', provider_type: 'inbox2', orgSlug: 'a-org', domainKey: 'dom_a' }];

// Roots are torn down after each test: a lingering probe stays subscribed to the
// sync bus and would recount alongside the one under test.
const roots = [];
function mount(accounts) {
  const Probe = () => { useChannelUnreadCounts(accounts); return null; };
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe)));
  roots.push(root);
  return root;
}

const flush = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
// useSyncRefresh only forwards data-change phases; lifecycle events are ignored.
const dataChange = () => act(() => syncManager.emit('sync', { phase: 'folder-progress', accountKey: 'org_a' }));

beforeEach(() => {
  getUnreadCount.mockReset();
  getUnreadCount.mockResolvedValue({ unread_count: 2 });
  useUnreadStore.setState({ total: 0, byChannel: {}, mutations: 0 });
});

afterEach(() => {
  act(() => { while (roots.length) roots.pop().unmount(); });
});

describe('useChannelUnreadCounts', () => {
  it('counts the whole pool server-side, not one page of conversations', async () => {
    getUnreadCount.mockResolvedValue({ unread_count: 137 });
    mount(ACCOUNTS);
    await flush();
    expect(useUnreadStore.getState().byChannel.org_a).toBe(137);
  });

  it('narrows a per-domain tab to its own domain, keyed by the tab', async () => {
    mount(DOMAIN_TAB);
    await flush();
    // Addressed by the ORG (a dom_ id is not an org identifier), narrowed by domain.
    expect(getUnreadCount).toHaveBeenCalledWith('a-org', { folder: 'inbox', domain: 'dom_a' });
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(2);
  });

  it('recounts when a sync settles, so a background badge cannot go stale', async () => {
    mount(ACCOUNTS);
    await flush();
    expect(useUnreadStore.getState().byChannel.org_a).toBe(2);

    // Both threads get read elsewhere and a sync brings that home.
    getUnreadCount.mockResolvedValue({ unread_count: 0 });
    dataChange();
    await flush();
    expect(useUnreadStore.getState().byChannel.org_a).toBe(0);
  });

  it('ignores sync lifecycle noise — only a data change recounts', async () => {
    mount(ACCOUNTS);
    await flush();
    act(() => syncManager.emit('sync', { phase: 'started', accountKey: 'org_a' }));
    act(() => syncManager.emit('sync', { phase: 'completed', accountKey: 'org_a' }));
    await flush();
    expect(getUnreadCount).toHaveBeenCalledTimes(1);
  });

  it('does not overwrite an optimistic adjust with a pre-action count', async () => {
    // The recount is in flight when the user files a thread: its answer describes
    // the world before the click, so it must be dropped, not written.
    let release;
    getUnreadCount.mockReturnValue(new Promise(r => { release = r; }));
    mount(ACCOUNTS);
    await flush();

    useUnreadStore.getState().setChannelCount('org_a', 2);
    act(() => useUnreadStore.getState().adjust('org_a', -1)); // user spams a thread
    await act(async () => { release({ unread_count: 2 }); await flush(); });

    expect(useUnreadStore.getState().byChannel.org_a).toBe(1);
  });

  it('drops a removed account, but not a channel that has yet to load', async () => {
    // A fresh mount's first set is partial (MX tabs are synchronous, external
    // channels arrive a tick later) — pruning on it would blank their badges on
    // every navigation.
    useUnreadStore.setState({ byChannel: { chan_x: 5 }, total: 5 });
    const Probe = ({ accounts }) => { useChannelUnreadCounts(accounts); return null; };
    const root = createRoot(document.createElement('div'));
    roots.push(root);
    act(() => root.render(createElement(Probe, { accounts: ACCOUNTS })));
    await flush();
    expect(useUnreadStore.getState().byChannel.chan_x).toBe(5);

    // The channel lands: still a tab, still counted.
    const withChannel = [...ACCOUNTS, { key: 'chan_x', provider_type: 'gmail' }];
    act(() => root.render(createElement(Probe, { accounts: withChannel })));
    await flush();
    expect(useUnreadStore.getState().byChannel.chan_x).toBe(5);

    // Now it's removed — its count must not keep inflating the total.
    act(() => root.render(createElement(Probe, { accounts: ACCOUNTS })));
    await flush();
    expect(useUnreadStore.getState().byChannel).toEqual({ org_a: 2 });
    expect(useUnreadStore.getState().total).toBe(2);
  });
});
