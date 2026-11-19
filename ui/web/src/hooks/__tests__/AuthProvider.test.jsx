// @vitest-environment jsdom
//
// The one rule that matters here: a failed session restore must distinguish
// "the server rejected your credentials" (sign out, wipe the token) from "the
// server is unreachable" (stay signed in, retry). Getting this backwards is
// what made a five-day API outage look like being logged out — on a desktop
// whose session was valid the whole time.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createElement, useContext, act } from 'react';
import { createRoot } from 'react-dom/client';

const api = {
  ready: Promise.resolve(null),
  token: 'stored-token',
  getAccount: vi.fn(),
  patch: vi.fn(() => Promise.resolve({})),
  setToken: vi.fn(),
};

vi.mock('../../lib/api', () => ({
  default: api,
  SESSION_EXPIRED_EVENT: 'inbox2:session-expired',
  TOKEN_ADOPTED_EVENT: 'inbox2:token-adopted',
}));
vi.mock('../../lib/pushSync', () => ({ default: { onForceLogout: vi.fn(), ensureSessionListener: vi.fn() } }));
vi.mock('../../lib/orgLiveMail', () => ({
  default: { reset: vi.fn(), syncOrgs: vi.fn(), onDomainChanged: vi.fn(() => () => {}) },
}));
vi.mock('../../lib/tauri', () => ({ isTauri: () => false }));
vi.mock('../../lib/log', () => ({ default: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

const { default: AuthProvider, AuthContext } = await import('../AuthProvider');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

async function renderAuth() {
  const ref = { current: null };
  const Probe = () => { ref.current = useContext(AuthContext); return null; };
  const root = createRoot(document.createElement('div'));
  await act(async () => {
    root.render(createElement(AuthProvider, null, createElement(Probe)));
  });
  return ref;
}

const httpError = (status) => Object.assign(new Error(`failed (${status})`), { status });

describe('AuthProvider session restore', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    api.token = 'stored-token';
  });

  it('reports offline (and keeps the token) when the API is unreachable', async () => {
    api.getAccount.mockRejectedValue(httpError(502));
    const auth = await renderAuth();

    expect(auth.current.offline).toBe(true);
    expect(auth.current.user).toBe(null);
    expect(auth.current.loading).toBe(false);
    expect(api.setToken).not.toHaveBeenCalled(); // the session is still valid
  });

  it('treats a network error (status 0) as offline too', async () => {
    api.getAccount.mockRejectedValue(httpError(0));
    const auth = await renderAuth();

    expect(auth.current.offline).toBe(true);
    expect(api.setToken).not.toHaveBeenCalled();
  });

  it('signs out — not offline — when the credentials are rejected', async () => {
    api.getAccount.mockRejectedValue(httpError(401));
    const auth = await renderAuth();

    expect(auth.current.offline).toBe(false);
    expect(auth.current.user).toBe(null);
    expect(api.setToken).toHaveBeenCalledWith(null);
  });

  it('clears offline once the API answers again', async () => {
    api.getAccount.mockRejectedValueOnce(httpError(502));
    const auth = await renderAuth();
    expect(auth.current.offline).toBe(true);

    api.getAccount.mockResolvedValue({
      account: { username: 'waseem' },
      organizations: [{ slug: 'inbox2-com', role: 'owner' }],
      current_org_slug: 'inbox2-com',
    });
    await act(async () => { auth.current.retryConnection(); });

    expect(auth.current.offline).toBe(false);
    expect(auth.current.user.username).toBe('waseem');
  });
});
