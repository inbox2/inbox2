import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Demo mode has to be read-only: a demo or a screenshot session must not send
// mail, write back a status to a provider, or PATCH anything on MX. Each of the
// three write boundaries is checked here, because a miss is invisible — the app
// would look exactly the same while quietly mutating a real mailbox.

vi.mock('../tauri', () => ({ isTauri: () => true, getOS: () => 'macos' }));
vi.mock('../secretStore', () => ({
  getSecret: vi.fn().mockResolvedValue(null),
  setSecret: vi.fn(),
  clearSecret: vi.fn(),
}));
const invoke = vi.fn();
vi.mock('@tauri-apps/api/core', () => ({ invoke: (...a) => invoke(...a) }));

function demoMode(on) {
  vi.stubGlobal('sessionStorage', {
    getItem: (k) => (on && k === 'inbox2:demo-mode' ? '1' : null),
    setItem: vi.fn(),
    removeItem: vi.fn(),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  invoke.mockResolvedValue(null);
});

// log.warn ships to the engine through invoke('js_log') too, so "nothing
// happened" means no PROVIDER command ran, not no invoke at all.
const providerCalls = () => invoke.mock.calls.filter(([cmd]) => cmd !== 'js_log');
afterEach(() => vi.unstubAllGlobals());

describe('demo mode is read-only', () => {
  it('refuses a provider send and never reaches the engine', async () => {
    demoMode(true);
    vi.resetModules();
    const { sendMessage } = await import('../providers/index.js');
    await expect(sendMessage('acct', { toAddress: 'a@b.com' })).rejects.toThrow(/demo data is on/i);
    expect(providerCalls()).toEqual([]);
  });

  it('refuses a provider write-back (archive / read / priority)', async () => {
    demoMode(true);
    vi.resetModules();
    const { performAction, setPriority, respondToInvite } = await import('../providers/index.js');
    await expect(performAction('acct', ['c1'], 'archive')).rejects.toThrow(/demo data is on/i);
    await expect(setPriority('acct', ['c1'], true, true)).rejects.toThrow(/demo data is on/i);
    await expect(respondToInvite('acct', 'm1', 'a1', 'accepted')).rejects.toThrow(/demo data is on/i);
    expect(providerCalls()).toEqual([]);
  });

  it('still lets reads through', async () => {
    demoMode(true);
    vi.resetModules();
    invoke.mockResolvedValue({ body_html: '<p>real</p>', body_plain: 'real', attachments: [] });
    const { fetchMessage } = await import('../providers/index.js');
    const msg = await fetchMessage('acct', 'msg1');
    expect(invoke).toHaveBeenCalledWith('fetch_message', { accountKey: 'acct', messageKey: 'msg1' });
    // …scrubbed on the way out: a live provider body never sees the SQLite scrub.
    expect(msg.body_plain).not.toBe('real');
  });

  it('lets writes through once demo mode is off', async () => {
    demoMode(false);
    vi.resetModules();
    const { performAction } = await import('../providers/index.js');
    await performAction('acct', ['c1'], 'archive');
    expect(invoke).toHaveBeenCalledWith('perform_conversation_action', {
      accountKey: 'acct', conversationKeys: ['c1'], action: 'archive',
    });
  });

  it('refuses every MX write but keeps reads and auth working', async () => {
    demoMode(true);
    vi.resetModules();
    const fetchSpy = vi.fn().mockResolvedValue({ ok: true, status: 200, text: async () => '{}' });
    vi.stubGlobal('fetch', fetchSpy);

    const api = (await import('../api')).default;
    await expect(api.post('/orgs/org_1/messages', {})).rejects.toThrow(/demo data is on/i);
    await expect(api.patch('/orgs/org_1/conversations/c1', {})).rejects.toThrow(/demo data is on/i);
    expect(fetchSpy).not.toHaveBeenCalled();

    await api.get('/orgs/org_1/conversations');
    // Signing in must still work — the read-only rule is about mail, not auth.
    await api.post('/auth/login', { email: 'a@b.com' });
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('hides raw MIME rather than trying to scrub it', async () => {
    demoMode(true);
    vi.resetModules();
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    const api = (await import('../api')).default;
    const { DEMO_HIDDEN_SOURCE } = await import('../demoData');
    expect(await api.getMessageRaw('org_1', 'conv_1', 'msg_1')).toBe(DEMO_HIDDEN_SOURCE);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('queues nothing for MX while demo mode is on', async () => {
    demoMode(true);
    vi.resetModules();
    const action = vi.fn();
    vi.doMock('../mxMirror.js', () => ({ default: { action } }));
    vi.doMock('../tauri.js', () => ({ isTauri: () => true, getOS: () => 'macos' }));
    vi.doMock('../localData.js', () => ({ mirroredOrg: async () => 'org_1' }));
    const api = (await import('../localFirstApi.js')).default;

    // The mirror holds the real mail: a demo click must not write to it, nor queue
    // anything the engine would send the moment it can.
    expect(await api.bulkConversations('org_1', ['c1'], 'archive')).toEqual({ success: true, _demo: true });
    expect(action).not.toHaveBeenCalled();
  });
});
