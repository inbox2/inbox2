import { describe, it, expect, vi, beforeEach } from 'vitest';

// Regression: the engine persists the cloud bearer under the BARE name
// `cloud_auth_token`, while getSecret() reads the webview `kv:` namespace. A
// store holding a good engine token therefore read as empty, AuthProvider's
// canRestore went false, and the desktop silently signed out of MX — local
// channels kept syncing, so it looked like "MX is gone" after an app rebuild.
// get_rails_token bridges the two namespaces.

vi.mock('../tauri', () => ({ isTauri: () => true }));

const getSecret = vi.fn();
const setSecret = vi.fn();
vi.mock('../secretStore', () => ({
  getSecret: (...a) => getSecret(...a),
  setSecret: (...a) => setSecret(...a),
  clearSecret: vi.fn(),
}));

const invoke = vi.fn();
vi.mock('@tauri-apps/api/core', () => ({ invoke: (...a) => invoke(...a) }));

async function freshApi() {
  vi.resetModules();
  return (await import('../api')).default;
}

beforeEach(() => {
  vi.clearAllMocks();
  invoke.mockResolvedValue(null);
});

describe('desktop bearer hydration', () => {
  it('falls back to the engine token when the webview store is empty', async () => {
    getSecret.mockResolvedValue(null);
    invoke.mockResolvedValue('ink_from_engine');

    const api = await freshApi();
    await api.ready;

    expect(invoke).toHaveBeenCalledWith('get_rails_token');
    expect(api.token).toBe('ink_from_engine');
  });

  it('re-seeds the webview namespace so the next boot hits the fast path', async () => {
    getSecret.mockResolvedValue(null);
    invoke.mockResolvedValue('ink_from_engine');

    const api = await freshApi();
    await api.ready;

    expect(setSecret).toHaveBeenCalledWith('cloud_auth_token', 'ink_from_engine');
  });

  it('uses the webview store when it has the token, without asking the engine', async () => {
    getSecret.mockResolvedValue('ink_from_kv');

    const api = await freshApi();
    await api.ready;

    expect(api.token).toBe('ink_from_kv');
    expect(invoke).not.toHaveBeenCalled();
  });

  it('stays signed out when neither store has a bearer', async () => {
    getSecret.mockResolvedValue(null);
    invoke.mockResolvedValue(null);

    const api = await freshApi();
    await api.ready;

    expect(api.token).toBe(null);
  });

  it('does not throw when the engine command is unavailable', async () => {
    getSecret.mockResolvedValue(null);
    invoke.mockRejectedValue(new Error('command not found'));

    const api = await freshApi();
    await expect(api.ready).resolves.toBeDefined();
    expect(api.token).toBe(null);
  });
});
