import { describe, it, expect } from 'vitest';
import { channelShortLabel } from '../providerTypes';

const gmail = (email) => ({ provider_type: 'gmail', email_address: email });

describe('channelShortLabel', () => {
  it('shows the domain when no other channel shares it', () => {
    const a = gmail('waseem@sadiq.nl');
    expect(channelShortLabel(a, [a, gmail('waseem@tuli.com')])).toBe('sadiq.nl');
  });

  it('keeps the full address when two channels share a domain, in any case', () => {
    const a = gmail('one@gmail.com');
    const b = gmail('Two@Gmail.com');
    expect(channelShortLabel(a, [a, b])).toBe('one@gmail.com');
    expect(channelShortLabel(b, [a, b])).toBe('Two@Gmail.com');
  });

  it('does not count a subdomain as the same domain', () => {
    const a = gmail('me@sadiq.nl');
    expect(channelShortLabel(a, [a, gmail('me@mail.sadiq.nl')])).toBe('sadiq.nl');
  });

  it('leaves a label without an address as it is', () => {
    const mx = { provider_type: 'inbox2', display_name: 'inbox2.com', email_address: 'inbox2.com' };
    expect(channelShortLabel(mx, [mx])).toBe('inbox2.com');
  });
});
