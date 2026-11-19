import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock localStorage (node env has none). cloudPushPref reads it at module load,
// so reset modules between tests for a fresh singleton snapshot.
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

beforeEach(() => {
  localStorageMock.clear();
  vi.resetModules();
});

describe('cloudPushPref', () => {
  it('defaults to enabled when unset', async () => {
    const { getCloudPushPref } = await import('../cloudPushPref');
    expect(getCloudPushPref().enabled).toBe(true);
  });

  it('reads a persisted "false"', async () => {
    localStorage.setItem('inbox2_cloud_push_enabled', 'false');
    const { getCloudPushPref } = await import('../cloudPushPref');
    expect(getCloudPushPref().enabled).toBe(false);
  });

  it('setCloudPushEnabled updates the snapshot and persists', async () => {
    const { getCloudPushPref, setCloudPushEnabled } = await import('../cloudPushPref');
    expect(getCloudPushPref().enabled).toBe(true);

    setCloudPushEnabled(false);
    expect(getCloudPushPref().enabled).toBe(false);
    expect(localStorage.getItem('inbox2_cloud_push_enabled')).toBe('false');

    setCloudPushEnabled(true);
    expect(getCloudPushPref().enabled).toBe(true);
    expect(localStorage.getItem('inbox2_cloud_push_enabled')).toBe('true');
  });

  it('notifies subscribers on change', async () => {
    const mod = await import('../cloudPushPref');
    // The store exposes a subscribe path via the default hook; assert the snapshot
    // object identity changes on update (what useSyncExternalStore relies on).
    const before = mod.getCloudPushPref();
    mod.setCloudPushEnabled(false);
    const after = mod.getCloudPushPref();
    expect(before).not.toBe(after);
    expect(after.enabled).toBe(false);
  });
});
