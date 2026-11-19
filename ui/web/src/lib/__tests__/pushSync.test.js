import { describe, it, expect, vi, beforeEach } from 'vitest';

// The boot race: PushSyncChannel opens as soon as the user is authenticated
// (force_logout), so a channel_sync signal can land before the engine has listed
// the local accounts. It must be replayed, not dropped.
const resyncChannel = vi.fn(() => Promise.resolve());
const emit = vi.fn();
let accounts = [];

vi.mock('../sync-manager', () => ({ default: { resyncChannel: (k) => resyncChannel(k), emit: (...a) => emit(...a) } }));
vi.mock('../tauri', () => ({ isTauri: () => true }));
vi.mock('../cable', () => ({ getConsumer: () => ({ subscriptions: { create: () => ({}) } }) }));
vi.mock('../api', () => ({ default: { getToken: () => Promise.resolve(null) } }));
vi.mock('../cloudPushPref', () => ({ getCloudPushPref: () => ({ enabled: true }) }));
vi.mock('../../stores/accountStore', () => ({
  default: { getState: () => ({ externalAccounts: accounts }) },
}));

let pushSync;
beforeEach(async () => {
  vi.resetModules();
  resyncChannel.mockClear();
  emit.mockClear();
  accounts = [];
  pushSync = (await import('../pushSync')).default;
});

const signal = { type: 'channel_sync', provider: 'gmail', email: 'Waseem@Lalaaji.com' };
const account = { key: 'acc_1', email_address: 'waseem@lalaaji.com', provider_type: 'gmail' };

describe('pushSync deferred signals', () => {
  it('replays a signal that arrived before the accounts hydrated', async () => {
    pushSync._onSignal(signal);
    expect(resyncChannel).not.toHaveBeenCalled();

    accounts = [account];
    await pushSync.ensureForAll(accounts);
    expect(resyncChannel).toHaveBeenCalledWith('acc_1');
  });

  it('syncs directly when the account is already known, and replays once', async () => {
    accounts = [account];
    pushSync._onSignal(signal);
    expect(resyncChannel).toHaveBeenCalledTimes(1);

    await pushSync.ensureForAll(accounts);
    expect(resyncChannel).toHaveBeenCalledTimes(1);
  });

  it('keeps holding a signal whose mailbox never shows up', async () => {
    pushSync._onSignal(signal);
    await pushSync.ensureForAll([{ key: 'acc_2', email_address: 'other@x.com' }]);
    expect(resyncChannel).not.toHaveBeenCalled();

    await pushSync.ensureForAll([account]);
    expect(resyncChannel).toHaveBeenCalledWith('acc_1');
  });
});

describe('pushSync MX new-mail alerts', () => {
  it('feeds the Rails alert into the new-message bus in the engine payload shape', () => {
    pushSync._onSignal({
      type: 'new_message', organization_id: 'org_1', workspace_slug: 'acme-com',
      conversation_id: 'conv_1', message_id: 'msg_1',
      from_address: 'Ann <ann@x.com>', subject: 'Hi', snippet: 'hello',
    });
    expect(emit).toHaveBeenCalledWith('new-message', expect.objectContaining({
      key: 'conv_1', messageKey: 'msg_1', providerType: 'inbox2',
      orgId: 'org_1', orgSlug: 'acme-com', from_address: 'Ann <ann@x.com>', subject: 'Hi',
    }));
    expect(resyncChannel).not.toHaveBeenCalled();
  });
});
