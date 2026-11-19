import { describe, it, expect, vi } from 'vitest';

// The ingress closes sockets on config changes; broadcasts sent meanwhile are lost.
// A reconnect (not the first connect) must trigger the same refresh a signal would.
let handlers;
vi.mock('../cable', () => ({ getConsumer: () => ({ subscriptions: { create: (_p, h) => { handlers = h; return { unsubscribe() {} }; } } }) }));
vi.mock('../tauri.js', () => ({ isTauri: () => false }));
vi.mock('../mxMirror', () => ({ default: { onChange: () => {}, kick: () => {} } }));

describe('orgLiveMail reconnect catch-up', () => {
  it('refetches on reconnect, not on the first connect', async () => {
    vi.useFakeTimers();
    const orgLiveMail = (await import('../orgLiveMail')).default;
    const onMail = vi.fn();
    const onDomain = vi.fn();
    orgLiveMail.onNewMail(onMail);
    orgLiveMail.onDomainChanged(onDomain);
    orgLiveMail.syncOrgs(['org_1']);

    handlers.connected();
    vi.runAllTimers();
    expect(onMail).not.toHaveBeenCalled();
    expect(onDomain).not.toHaveBeenCalled();

    handlers.disconnected();
    handlers.connected();
    vi.runAllTimers();
    expect(onMail).toHaveBeenCalledTimes(1);
    expect(onDomain).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });
});
