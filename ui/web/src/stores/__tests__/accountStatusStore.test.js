// @vitest-environment jsdom
//
// The trap this guards: `seed` refuses to overwrite a key it already tracks, so
// any status transition that happens while nothing is subscribed is lost for
// good. Reconnecting an account from Settings (no ChromeBar mounted, so the
// hook that used to own the subscription was gone) left the channel tile red
// until the next 60s poll re-emitted. The subscription therefore lives in the
// store module, active on every route.
import { describe, it, expect, beforeEach, vi } from 'vitest';

const listeners = new Map();
vi.mock('../../lib/sync-manager', () => ({
  default: {
    on: (event, cb) => {
      listeners.set(event, [...(listeners.get(event) || []), cb]);
      return () => {};
    },
  },
}));

const emit = (event, payload) => (listeners.get(event) || []).forEach(cb => cb(payload));

const { default: useAccountStatusStore, needsReconnect } = await import('../accountStatusStore');

describe('accountStatusStore', () => {
  beforeEach(() => { useAccountStatusStore.setState({ byKey: {} }); });

  it('tracks engine transitions with no component mounted', () => {
    emit('account-status', { accountKey: 'acc_a', status: 'needs_reauth' });
    expect(needsReconnect(useAccountStatusStore.getState().byKey.acc_a)).toBe(true);

    emit('account-status', { accountKey: 'acc_a', status: 'connected' });
    expect(needsReconnect(useAccountStatusStore.getState().byKey.acc_a)).toBe(false);
  });

  it('ignores malformed events', () => {
    emit('account-status', { status: 'connected' });
    emit('account-status', { accountKey: 'acc_b' });
    expect(useAccountStatusStore.getState().byKey).toEqual({});
  });

  it('seeds unknown accounts but never clobbers a live transition', () => {
    emit('account-status', { accountKey: 'acc_a', status: 'connected' });
    useAccountStatusStore.getState().seed([
      { key: 'acc_a', status: 'needs_reauth' }, // stale list read — must not win
      { key: 'acc_c', status: 'error' },
    ]);

    expect(useAccountStatusStore.getState().byKey.acc_a).toBe('connected');
    expect(useAccountStatusStore.getState().byKey.acc_c).toBe('error');
  });

  it('only needs_reauth raises the reconnect UI', () => {
    expect(needsReconnect('needs_reauth')).toBe(true);
    expect(needsReconnect('error')).toBe(false); // transient — the poll recovers it
    expect(needsReconnect('connected')).toBe(false);
    expect(needsReconnect(undefined)).toBe(false);
  });
});
