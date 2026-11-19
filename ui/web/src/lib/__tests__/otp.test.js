import { describe, it, expect } from 'vitest';
import { codeForClipboard, siteIconUrl } from '../otp.js';

// Detection is tested against fixtures/parity/fixtures.json (Rust + Ruby).
describe('otp card helpers', () => {
  it('copies the code without its grouping', () => {
    expect(codeForClipboard('123-456')).toBe('123456');
    expect(codeForClipboard('123 456')).toBe('123456');
  });

  it('names the site: the link host, else the sender domain', () => {
    expect(siteIconUrl({ link: 'https://husttle.com/x', host: 'husttle.com' })).toBe('https://husttle.com/favicon.ico');
    expect(siteIconUrl({ code: '1234' }, 'noreply@messy.sh')).toBe('https://messy.sh/favicon.ico');
    expect(siteIconUrl({ code: '1234' }, '')).toBeNull();
    // Every mail card asks now, not just sign-in ones
    expect(siteIconUrl(null, 'ops@messy.sh')).toBe('https://messy.sh/favicon.ico');
    // A freemail favicon names the provider, not the sender
    expect(siteIconUrl(null, 'someone@gmail.com')).toBeNull();
    expect(siteIconUrl(undefined, undefined)).toBeNull();
  });
});
