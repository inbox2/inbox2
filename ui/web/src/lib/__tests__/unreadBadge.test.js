import { describe, it, expect, beforeEach } from 'vitest';
import { unreadDelta, CONV_ACTION } from '../conversationActions';
import { CONV_STATUS } from '../conversationStatus';
import useUnreadStore from '../../stores/unreadStore';

// The badge moves in two ways and only two: an optimistic delta the instant you
// click (unreadDelta → adjust), and the recount that replaces it with the truth
// (setChannelCount, written only by useChannelUnreadCounts). Between them they
// decide whether the number on the tab is right.

describe('unreadDelta', () => {
  it('clears one unread for read and for anything that leaves the inbox', () => {
    for (const action of [CONV_ACTION.MARK_READ, CONV_ACTION.ARCHIVE, CONV_ACTION.TRASH, CONV_ACTION.SPAM]) {
      expect(unreadDelta(action, true)).toBe(-1);
      // Already read: the thread was never in the count, so nothing moves.
      expect(unreadDelta(action, false)).toBe(0);
    }
  });

  it('puts one back for mark-unread and for a restore to the inbox', () => {
    expect(unreadDelta(CONV_ACTION.MARK_UNREAD, false)).toBe(1);
    expect(unreadDelta(CONV_ACTION.MARK_UNREAD, true)).toBe(0);
    // An unread thread coming back from spam/trash/archive re-enters the pool.
    for (const action of [CONV_STATUS.OPEN, CONV_ACTION.MOVE_TO_INBOX, CONV_ACTION.UNSPAM, CONV_ACTION.UNTRASH]) {
      expect(unreadDelta(action, true, false)).toBe(1);
      expect(unreadDelta(action, false, false)).toBe(0);
    }
  });

  it('leaves the badge alone for triage — the thread stays unread in the inbox', () => {
    for (const action of ['set_quadrant:DO_FIRST', 'triage', 'untriage', 'flag']) {
      expect(unreadDelta(action, true)).toBe(0);
      expect(unreadDelta(action, false)).toBe(0);
    }
  });

  it('ignores threads that are not in the pool the badge counts', () => {
    // Deleting an unread thread from inside Spam clears nothing from the inbox.
    for (const action of [CONV_ACTION.TRASH, CONV_ACTION.ARCHIVE, CONV_ACTION.MARK_READ]) {
      expect(unreadDelta(action, true, false)).toBe(0);
    }
    expect(unreadDelta(CONV_ACTION.MARK_UNREAD, false, false)).toBe(0);
    // Symmetrically, "restoring" something already in the inbox adds nothing.
    expect(unreadDelta(CONV_ACTION.UNSPAM, true, true)).toBe(0);
  });
});

describe('unreadStore', () => {
  beforeEach(() => useUnreadStore.setState({ total: 0, byChannel: {}, mutations: 0 }));

  const seed = (counts) => {
    for (const [k, n] of Object.entries(counts)) useUnreadStore.getState().setChannelCount(k, n);
  };

  it('moves one channel and the total without touching the others', () => {
    seed({ acc_a: 2, acc_b: 1 });
    expect(useUnreadStore.getState().total).toBe(3);

    useUnreadStore.getState().adjust('acc_a', -1);
    expect(useUnreadStore.getState().byChannel).toEqual({ acc_a: 1, acc_b: 1 });
    expect(useUnreadStore.getState().total).toBe(2);
  });

  it('never goes negative when a thread was already read elsewhere', () => {
    seed({ acc_a: 1 });
    useUnreadStore.getState().adjust('acc_a', -1);
    useUnreadStore.getState().adjust('acc_a', -1); // drift: nothing left to clear
    expect(useUnreadStore.getState().byChannel.acc_a).toBe(0);
    expect(useUnreadStore.getState().total).toBe(0);
  });

  it('ignores a missing key and a zero delta', () => {
    seed({ acc_a: 1 });
    useUnreadStore.getState().adjust(null, -1);
    useUnreadStore.getState().adjust(undefined, -1);
    useUnreadStore.getState().adjust('acc_a', 0);
    expect(useUnreadStore.getState().total).toBe(1);
  });

  it('is corrected by the next recount', () => {
    seed({ acc_a: 1 });
    useUnreadStore.getState().adjust('acc_a', -1);
    expect(useUnreadStore.getState().total).toBe(0);

    // The recount lands and says the thread is still unread — truth wins.
    useUnreadStore.getState().setChannelCount('acc_a', 1);
    expect(useUnreadStore.getState().total).toBe(1);
  });

  it('counts every adjust as a mutation, including one the clamp swallows', () => {
    // useChannelUnreadCounts drops an in-flight recount when this moves — a read
    // that started before the click describes the world before it.
    seed({ acc_a: 1 });
    expect(useUnreadStore.getState().mutations).toBe(0);
    useUnreadStore.getState().adjust('acc_a', -1);
    useUnreadStore.getState().adjust('acc_a', -1); // clamped at zero
    expect(useUnreadStore.getState().mutations).toBe(2);
  });

  it('prunes keys that are no longer tabs, so the total counts a mailbox once', () => {
    // A stray key (the org-slug fallback an older build wrote under a Space
    // filter) alongside the dom_ tab for the same mail: 2 + 2 read as 4 unread.
    useUnreadStore.setState({ byChannel: { dom_a: 2, 'waseem-org': 2 }, total: 4 });
    useUnreadStore.getState().pruneTo(['dom_a']);
    expect(useUnreadStore.getState().byChannel).toEqual({ dom_a: 2 });
    expect(useUnreadStore.getState().total).toBe(2);
  });

  it('round-trips an undo back to where it started', () => {
    seed({ acc_a: 1 });
    // Delete from the notification popup, then undo it.
    useUnreadStore.getState().adjust('acc_a', unreadDelta(CONV_ACTION.TRASH, true));
    expect(useUnreadStore.getState().total).toBe(0);
    useUnreadStore.getState().adjust('acc_a', unreadDelta(CONV_ACTION.UNTRASH, true, false));
    expect(useUnreadStore.getState().total).toBe(1);
  });
});
