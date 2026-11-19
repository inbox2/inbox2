// @vitest-environment jsdom
//
// Another tab signing out, or this tab's own 401, puts up the one signed-out
// screen over the page instead of dropping to the login route: the token and
// cached account go at once, the user stays mounted behind the screen, and the
// same account signing in again elsewhere lifts it.
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
  CLOUD_AUTH_TOKEN: 'cloud_auth_token',
  SESSION_EXPIRED_EVENT: 'inbox2:session-expired',
  TOKEN_ADOPTED_EVENT: 'inbox2:token-adopted',
}));
vi.mock('../../lib/secretStore', () => ({ getSecret: vi.fn(() => Promise.resolve('new-token')) }));
const pushSync = { onForceLogout: vi.fn(), ensureSessionListener: vi.fn(), _dropChannel: vi.fn() };
vi.mock('../../lib/pushSync', () => ({ default: pushSync }));
const orgLiveMail = { reset: vi.fn(), syncOrgs: vi.fn(), onDomainChanged: vi.fn(() => () => {}) };
vi.mock('../../lib/orgLiveMail', () => ({ default: orgLiveMail }));
const cable = { pauseCable: vi.fn(), resumeCable: vi.fn() };
vi.mock('../../lib/cable', () => cable);
const sealed = { clear: vi.fn() };
vi.mock('../../stores/sealedStore', () => ({ default: { getState: () => sealed } }));
vi.mock('../../lib/disk/engine/conversions', () => ({ clearAllConversions: vi.fn() }));
vi.mock('../../lib/tauri', () => ({ isTauri: () => false }));
vi.mock('../../lib/log', () => ({ default: { info: vi.fn(), warn: vi.fn(), error: vi.fn(), debug: vi.fn() } }));

const { default: AuthProvider, AuthContext } = await import('../AuthProvider');
const { AUTH_SIGNED_IN, AUTH_SIGNED_OUT } = await import('../../lib/authBroadcast');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const ME = { id: 'usr_me', username: 'me' };
const roots = [];

async function renderAuth() {
  const ref = { current: null };
  const Probe = () => { ref.current = useContext(AuthContext); return null; };
  const host = document.createElement('div');
  host.id = 'root';
  document.body.appendChild(host);
  const root = createRoot(host);
  roots.push(root);
  await act(async () => { root.render(createElement(AuthProvider, null, createElement(Probe))); });
  return ref;
}
const fromOtherTab = async (msg) => {
  const other = new BroadcastChannel('inbox2-auth');
  await act(async () => { other.postMessage(msg); await new Promise((r) => setTimeout(r, 30)); });
  other.close();
};
const screen = () => document.querySelector('[role="alertdialog"]');

describe('AuthProvider signed-out screen', () => {
  beforeEach(async () => {
    await act(async () => { roots.splice(0).forEach((r) => r.unmount()); });
    vi.clearAllMocks();
    document.body.innerHTML = '';
    localStorage.clear();
    api.getAccount.mockResolvedValue({ account: ME, organizations: [] });
  });

  it('another tab signing this account out: screen up, token, keys and live channels dropped, page kept mounted', async () => {
    const auth = await renderAuth();
    expect(auth.current.user).toEqual(ME);
    await fromOtherTab({ kind: AUTH_SIGNED_OUT, userId: ME.id });
    expect(screen()?.textContent).toContain('You are signed out');
    expect(document.activeElement?.textContent).toBe('Sign in again');
    expect(document.getElementById('root').hasAttribute('inert')).toBe(true);
    expect(api.setToken).toHaveBeenCalledWith(null);
    expect(sealed.clear).toHaveBeenCalled();
    expect(orgLiveMail.reset).toHaveBeenCalled();
    expect(pushSync._dropChannel).toHaveBeenCalled();
    expect(cable.pauseCable).toHaveBeenCalled();
    expect(auth.current.user).toEqual(ME); // still mounted behind the screen, so unsaved text survives

    // The same account signs in again elsewhere: the screen lifts and the tab carries on.
    await fromOtherTab({ kind: AUTH_SIGNED_IN, userId: ME.id });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    expect(screen()).toBe(null);
    expect(api.token).toBe('new-token');
    expect(cable.resumeCable).toHaveBeenCalled();
  });

  it('ignores another account signing out', async () => {
    await renderAuth();
    await fromOtherTab({ kind: AUTH_SIGNED_OUT, userId: 'usr_other' });
    expect(screen()).toBe(null);
    expect(api.setToken).not.toHaveBeenCalled();
  });

  it('a 401 in this tab shows the same screen and tells the other tabs', async () => {
    await renderAuth();
    const heard = [];
    const other = new BroadcastChannel('inbox2-auth');
    other.onmessage = ({ data }) => heard.push(data);
    await act(async () => { window.dispatchEvent(new CustomEvent('inbox2:session-expired')); await new Promise((r) => setTimeout(r, 30)); });
    expect(screen()?.textContent).toContain('Your session ended.');
    expect(heard).toEqual([{ kind: AUTH_SIGNED_OUT, userId: ME.id }]);
    other.close();
  });
});
