// @vitest-environment jsdom
// The unit project runs in node, which has no localStorage — and this module is
// nothing but localStorage semantics.
import { describe, it, expect, beforeEach, vi } from 'vitest';

// isStandaloneDesktop() is desktop-only, so pin isTauri true for these.
vi.mock('../tauri', () => ({ isTauri: () => true }));

const {
  SETUP_COMPLETE_KEY, SETUP_MODE,
  getSetupMode, setSetupMode, clearSetupMode, isSetupComplete, isStandaloneDesktop,
} = await import('../setupMode');

// The setup flag decides three things: whether the first-run wizard runs, whether
// a login is required, and whether cloud calls use a session or an API key. It
// used to be compared against raw literals in three places that disagreed — the
// wizard wrote '1' for MX, this module read `!== '1'` as standalone, and
// routes.jsx read `!== 'mx'` as standalone. An MX install satisfied both, so
// ProtectedRoute handed over the app without ever asking anyone to sign in.

describe('setup mode', () => {
  beforeEach(() => localStorage.clear());

  it('reports incomplete setup when nothing is stored', () => {
    expect(getSetupMode()).toBeNull();
    expect(isSetupComplete()).toBe(false);
  });

  it('round-trips each mode', () => {
    setSetupMode(SETUP_MODE.MX);
    expect(getSetupMode()).toBe(SETUP_MODE.MX);
    setSetupMode(SETUP_MODE.STANDALONE);
    expect(getSetupMode()).toBe(SETUP_MODE.STANDALONE);
  });

  it('treats MX as NOT standalone, so the login gate still applies', () => {
    setSetupMode(SETUP_MODE.MX);
    expect(isStandaloneDesktop()).toBe(false);
  });

  it('treats standalone as standalone', () => {
    setSetupMode(SETUP_MODE.STANDALONE);
    expect(isStandaloneDesktop()).toBe(true);
  });

  describe('legacy "1" value from installs in the wild', () => {
    it('reads as MX rather than as unset', () => {
      localStorage.setItem(SETUP_COMPLETE_KEY, '1');
      expect(getSetupMode()).toBe(SETUP_MODE.MX);
      // Critically: not null, or the user is thrown back into the wizard.
      expect(isSetupComplete()).toBe(true);
      expect(isStandaloneDesktop()).toBe(false);
    });

    it('migrates in place so the legacy value is read once', () => {
      localStorage.setItem(SETUP_COMPLETE_KEY, '1');
      getSetupMode();
      expect(localStorage.getItem(SETUP_COMPLETE_KEY)).toBe(SETUP_MODE.MX);
    });
  });

  it('clearing sends the user back to the wizard', () => {
    setSetupMode(SETUP_MODE.MX);
    clearSetupMode();
    expect(isSetupComplete()).toBe(false);
  });

  it('never writes a value that reads back as a different mode', () => {
    for (const m of [SETUP_MODE.MX, SETUP_MODE.STANDALONE]) {
      setSetupMode(m);
      expect(getSetupMode()).toBe(m);
    }
  });
});
