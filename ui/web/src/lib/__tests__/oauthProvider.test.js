import { describe, it, expect, beforeEach, vi } from 'vitest';

// api default export is read for the bearer token; give it a stable stub.
vi.mock('../api', () => ({ default: { token: 'test-token' } }));

import { createOAuthProvider } from '../oauthProvider';

function jsonResponse(body, ok = true, status = 200) {
  return {
    ok,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

beforeEach(() => {
  globalThis.fetch = vi.fn();
});

describe('createOAuthProvider', () => {
  it('builds the authorize URL under the provider segment with state + auth header', async () => {
    fetch.mockResolvedValueOnce(jsonResponse({ auth_url: 'https://consent', state: 'xyz' }));
    const google = createOAuthProvider('google');

    const result = await google.getAuthUrl('xyz', 'http://localhost:1234/cb');

    expect(result).toEqual({ auth_url: 'https://consent', state: 'xyz' });
    const [url, opts] = fetch.mock.calls[0];
    expect(url).toContain('/api/v1/auth/google/authorize?');
    expect(url).toContain('redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fcb');
    expect(url).toContain('state=xyz');
    expect(opts.headers.Authorization).toBe('Bearer test-token');
  });

  it('exchangeCode POSTs code + redirect_uri to the provider token endpoint', async () => {
    fetch.mockResolvedValueOnce(jsonResponse({ access_token: 'a', refresh_token: 'r', expires_in: 3600 }));
    const ms = createOAuthProvider('microsoft');

    const tokens = await ms.exchangeCode('the-code', 'http://localhost/cb');

    expect(tokens.access_token).toBe('a');
    const [url, opts] = fetch.mock.calls[0];
    expect(url).toBe('/api/v1/auth/microsoft/token');
    expect(opts.method).toBe('POST');
    expect(JSON.parse(opts.body)).toEqual({ code: 'the-code', redirect_uri: 'http://localhost/cb' });
  });

  it('refreshAccessToken POSTs the refresh token to the provider refresh endpoint', async () => {
    fetch.mockResolvedValueOnce(jsonResponse({ access_token: 'a2', expires_in: 3600 }));
    const google = createOAuthProvider('google');

    await google.refreshAccessToken('refresh-123');

    const [url, opts] = fetch.mock.calls[0];
    expect(url).toBe('/api/v1/auth/google/refresh');
    expect(JSON.parse(opts.body)).toEqual({ refresh_token: 'refresh-123' });
  });

  it('throws with the response body on a non-ok exchange', async () => {
    fetch.mockResolvedValueOnce(jsonResponse('invalid_grant', false, 400));
    const google = createOAuthProvider('google');

    await expect(google.exchangeCode('bad', 'http://localhost/cb')).rejects.toThrow(
      /Couldn't finish sign-in: invalid_grant/,
    );
  });
});
