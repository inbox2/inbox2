// @vitest-environment jsdom
//
// The channel inbox no longer derives its tab badge from the conversation list
// it's holding (one page, so the number meant something different per screen) —
// it moves the badge by a delta as actions run. The delta must respect WHICH
// FOLDER is on screen: deleting a thread from inside Spam clears nothing from
// the inbox count, while moving one back to the inbox adds to it.
//
// No @testing-library in this repo, so the hook runs in a bare React root
// (same pattern as useChannelUnreadCounts.test.js).
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createElement, act } from 'react';
import { createRoot } from 'react-dom/client';

vi.mock('../../lib/tauri', () => ({ isTauri: () => false, getOS: () => 'macos' }));
vi.mock('../../lib/log', () => ({ default: { warn: () => {}, info: () => {}, error: () => {} } }));

const bulkConversations = vi.fn(async () => ({}));
vi.mock('../../lib/localFirstApi', () => ({
  default: {
    bulkConversations: (...args) => bulkConversations(...args),
    getTags: async () => ({ tags: [] }),
    put: async () => ({}),
  },
}));

const { default: useUnreadStore } = await import('../../stores/unreadStore');
const { default: useConversationActions } = await import('../useConversationActions');
const { CONV_ACTION } = await import('../../lib/conversationActions');
const { CONV_STATUS } = await import('../../lib/conversationStatus');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

const roots = [];
function mount({ conversations, inInboxView = true }) {
  const held = {};
  const Probe = () => {
    held.current = useConversationActions({
      activeAccountKey: null,
      orgId: 'a-org',
      conversations,
      displayedConversations: conversations,
      selectedId: null,
      setConversations: () => {},
      setSelectedConv: () => {},
      badgeKey: 'dom_a',
      inInboxView,
    });
    return null;
  };
  const root = createRoot(document.createElement('div'));
  act(() => root.render(createElement(Probe)));
  roots.push(root);
  return held;
}

const run = async (held, ids, action) => {
  await act(async () => { await held.current.executeAction(ids, action, { record: false }); });
};

const INBOX_ROWS = [
  { id: 'c1', read: false, status: CONV_STATUS.OPEN },
  { id: 'c2', read: true, status: CONV_STATUS.OPEN },
  { id: 'c3', read: false, status: CONV_STATUS.OPEN },
];

beforeEach(() => {
  bulkConversations.mockClear();
  useUnreadStore.setState({ byChannel: { dom_a: 2 }, total: 2, mutations: 0 });
});

afterEach(() => {
  act(() => { while (roots.length) roots.pop().unmount(); });
});

describe('useConversationActions badge', () => {
  it('clears one per unread thread filed from the inbox', async () => {
    const held = mount({ conversations: INBOX_ROWS });
    await run(held, ['c1'], CONV_ACTION.SPAM);
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(1);
  });

  it('counts a bulk action once per unread thread in it', async () => {
    const held = mount({ conversations: INBOX_ROWS });
    // c2 is already read — only c1 and c3 are in the count.
    await run(held, ['c1', 'c2', 'c3'], CONV_ACTION.ARCHIVE);
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(0);
  });

  it('leaves the badge alone for an action taken inside Spam/Trash', async () => {
    const held = mount({
      conversations: [{ id: 's1', read: false, status: CONV_STATUS.SPAM }],
      inInboxView: false,
    });
    await run(held, ['s1'], CONV_ACTION.TRASH);
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(2);
  });

  it('adds one back when an unread thread is moved out of Spam into the inbox', async () => {
    const held = mount({
      conversations: [{ id: 's1', read: false, status: CONV_STATUS.SPAM }],
      inInboxView: false,
    });
    await run(held, ['s1'], CONV_ACTION.MOVE_TO_INBOX);
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(3);
  });

  it('does not move the badge when the server refuses the action', async () => {
    bulkConversations.mockRejectedValueOnce(new Error('502'));
    const held = mount({ conversations: INBOX_ROWS });
    await run(held, ['c1'], CONV_ACTION.SPAM);
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(2);
  });

  it('leaves the badge alone for triage — the thread stays unread in the inbox', async () => {
    const held = mount({ conversations: INBOX_ROWS });
    await act(async () => { await held.current.executePriority(['c1'], 'DO_FIRST', { record: false }); });
    expect(useUnreadStore.getState().byChannel.dom_a).toBe(2);
  });
});
