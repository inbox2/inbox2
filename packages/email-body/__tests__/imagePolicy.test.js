import { describe, it, expect } from 'vitest';
import { shouldProxyImages } from '../src/imagePolicy.js';

const base = {
  proxyEnabled: false,
  isSafeSender: false,
  alwaysShow: false,
  shownOnce: false,
  hasToken: false,
};

describe('shouldProxyImages', () => {
  it('never proxies without a token, even when opted in', () => {
    expect(shouldProxyImages({ ...base, proxyEnabled: true })).toBe(false);
    expect(shouldProxyImages({ ...base, isSafeSender: true })).toBe(false);
    expect(shouldProxyImages({ ...base, alwaysShow: true })).toBe(false);
    expect(shouldProxyImages({ ...base, shownOnce: true })).toBe(false);
  });

  it('proxies with a token when any opt-in is set', () => {
    expect(shouldProxyImages({ ...base, hasToken: true, proxyEnabled: true })).toBe(true);
    expect(shouldProxyImages({ ...base, hasToken: true, isSafeSender: true })).toBe(true);
    expect(shouldProxyImages({ ...base, hasToken: true, alwaysShow: true })).toBe(true);
    expect(shouldProxyImages({ ...base, hasToken: true, shownOnce: true })).toBe(true);
  });

  it('stays blocked with a token but no opt-in (default privacy)', () => {
    expect(shouldProxyImages({ ...base, hasToken: true })).toBe(false);
  });
});
