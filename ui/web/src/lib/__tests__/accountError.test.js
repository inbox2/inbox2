import { describe, it, expect } from 'vitest';
import { accountErrorText } from '../accountError';

describe('accountErrorText', () => {
  it('turns a Gmail quota 403 into one plain line', () => {
    const t = accountErrorText('HTTP 403: Gmail: { "error": { "message": "Quota exceeded for quota metric" } }');
    expect(t).not.toContain('{');
    expect(t).toContain('slow down');
  });
  it('also knows the quotaExceeded reason', () => {
    expect(accountErrorText('HTTP 403: { "reason": "quotaExceeded" }')).toContain('slow down');
  });
  it('keeps any other reason and has a default', () => {
    expect(accountErrorText('HTTP 401: invalid_grant')).toBe('HTTP 401: invalid_grant');
    expect(accountErrorText(null)).toContain("We'll try again");
  });
});
