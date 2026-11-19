import { describe, it, expect } from 'vitest';
import { meetPreview } from '../meetPreview';

describe('meetPreview', () => {
  const meet = { invitee: { name: 'Waseem Sadiq', avatar_url: null }, organization: 'Lalaaji', duration_minutes: 60 };

  it('names the person, the length and the org', () => {
    const { title, html } = meetPreview(meet, 'https://mail.inbox2.com/meet/abc', 'https://mail.inbox2.com/favicon-512.png');
    expect(title).toBe('Meet with Waseem Sadiq');
    expect(html).toContain('<meta property="og:title" content="Meet with Waseem Sadiq" />');
    expect(html).toContain('60-minute meeting · Lalaaji. Waseem confirms every request.');
    expect(html).toContain('content="https://mail.inbox2.com/favicon-512.png"');
  });

  it('escapes names so a crafted display name cannot break out of the tag', () => {
    const { html } = meetPreview({ invitee: { name: '"><script>x</script>' } }, 'u', 'i');
    expect(html).not.toContain('<script>');
    expect(html).toContain('&quot;&gt;&lt;script&gt;');
  });
});
