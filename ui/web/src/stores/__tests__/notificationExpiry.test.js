// @vitest-environment jsdom
//
// A meeting card must not outlive its meeting: the laptop sleeps through the
// 10:30 reminder and the lid opens at 14:00 to a card still saying "Starting now".
import { describe, it, expect, vi, afterEach } from 'vitest';
import useNotificationStore, { expiresAt, MEETING_EVENT } from '../notificationStore';
import { START_GRACE_MS } from '../../lib/meetingAlerts';

const meeting = (startAt, endAt, priority = 'urgent') => ({
  eventType: MEETING_EVENT, priority, key: 'mtg:x', startAt, endAt,
});
const iso = (ms) => new Date(ms).toISOString();

afterEach(() => { vi.useRealTimers(); useNotificationStore.setState({ notifications: [], history: [] }); });

describe('alert expiry', () => {
  it('caps a persist-until-touched meeting card at 5 minutes past the start', () => {
    const now = Date.now();
    expect(expiresAt(meeting(iso(now), iso(now + 3600000)), now)).toBe(now + START_GRACE_MS);
  });

  it('keeps the shorter of dwell and the start grace', () => {
    const now = Date.now();
    // 14s dwell vs a meeting that started 5 minutes ago — already spent.
    expect(expiresAt(meeting(iso(now - START_GRACE_MS), null, 'high'), now)).toBe(now);
    // 14s dwell vs a meeting starting now.
    expect(expiresAt(meeting(iso(now), null, 'high'), now)).toBe(now + 14000);
  });

  it('leaves mail alone: urgent mail still persists, normal mail keeps its dwell', () => {
    const now = Date.now();
    expect(expiresAt({ priority: 'urgent' }, now)).toBeNull();
    expect(expiresAt({ priority: 'normal' }, now)).toBe(now + 8000);
  });

  it('keeps a T-10 meeting card up until 5 minutes in, whatever mail arrives', () => {
    vi.useFakeTimers();
    const now = Date.now();
    const start = now + 10 * 60 * 1000;
    const store = useNotificationStore.getState();
    store.show(meeting(iso(start), iso(start + 3600000)));
    ['a', 'b', 'c'].forEach((k) => store.show({ key: k }));
    vi.advanceTimersByTime(14 * 60 * 1000);
    expect(useNotificationStore.getState().notifications.map(n => n.key)).toEqual(['mtg:x']);
    vi.advanceTimersByTime(2 * 60 * 1000);
    expect(useNotificationStore.getState().notifications).toHaveLength(0);
  });

  it('drops a card whose meeting ended while the timers were asleep', () => {
    vi.useFakeTimers();
    const now = Date.now();
    useNotificationStore.getState().show(meeting(iso(now), iso(now + 60 * 60 * 1000)));
    expect(useNotificationStore.getState().notifications).toHaveLength(1);
    // Sleep past the end of the meeting, then let one tick run.
    vi.setSystemTime(now + 3 * 60 * 60 * 1000);
    vi.advanceTimersByTime(1000);
    expect(useNotificationStore.getState().notifications).toHaveLength(0);
  });
});
