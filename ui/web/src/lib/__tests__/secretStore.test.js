import { describe, it, expect, beforeEach } from 'vitest';
import { getSecret, setSecret, clearSecret } from '../secretStore';

// node env → isTauri() is false, so secretStore exercises the web localStorage
// fallback (keyed `inbox2_<name>`). The desktop/engine path is covered by the
// Rust app_secret / kv-namespacing tests.
const localStorageMock = (() => {
  let store = {};
  return {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
    clear: () => { store = {}; },
  };
})();
Object.defineProperty(globalThis, 'localStorage', { value: localStorageMock, configurable: true });

beforeEach(() => localStorageMock.clear());

describe('secretStore (web fallback)', () => {
  it('returns null for an unset secret', async () => {
    expect(await getSecret('apollo_api_key')).toBe(null);
  });

  it('round-trips under the legacy inbox2_<name> key', async () => {
    await setSecret('apollo_api_key', 'abc123');
    expect(localStorage.getItem('inbox2_apollo_api_key')).toBe('abc123');
    expect(await getSecret('apollo_api_key')).toBe('abc123');
  });

  it('reads a pre-existing legacy localStorage value', async () => {
    localStorage.setItem('inbox2_apollo_api_key', 'legacy-key');
    expect(await getSecret('apollo_api_key')).toBe('legacy-key');
  });

  it('clearSecret removes it', async () => {
    await setSecret('apollo_api_key', 'abc123');
    await clearSecret('apollo_api_key');
    expect(await getSecret('apollo_api_key')).toBe(null);
    expect(localStorage.getItem('inbox2_apollo_api_key')).toBe(null);
  });
});
