import { describe, it, expect } from 'vitest';
import { socialRowProps } from '../socialRowProps';
import { META_CHANNEL, META_KIND } from '../../../lib/providerTypes';

const baseDm = {
  id: 'conv_ig_1',
  from_address: '@theo.makes',
  from_avatar: 'https://cdn/avatar.jpg',
  snippet: 'would love to collab on a type project!',
  updated_at: '2026-06-26T10:00:00Z',
  read: false,
  providerType: 'instagram',
  channel: META_CHANNEL.INSTAGRAM,
  kind: META_KIND.DM,
  message_count: 1,
};

describe('socialRowProps', () => {
  it('maps a DM conversation to SocialListRow props', () => {
    const p = socialRowProps(baseDm);
    expect(p.sender).toBe('@theo.makes');
    expect(p.avatar).toBe('https://cdn/avatar.jpg');
    expect(p.channel).toBe(META_CHANNEL.INSTAGRAM);
    expect(p.kind).toBe(META_KIND.DM);
    expect(p.preview).toBe('would love to collab on a type project!');
    expect(p.unread).toBe(true);
    expect(p.count).toBe(1);
  });

  it('strips a "Comment: \'…\'" wrapper for comment rows', () => {
    const p = socialRowProps({
      ...baseDm,
      kind: META_KIND.COMMENT,
      snippet: "Comment: 'This palette is everything 🔥'",
    });
    expect(p.preview).toBe('This palette is everything 🔥');
    expect(p.kind).toBe(META_KIND.COMMENT);
  });

  it('keeps the raw snippet for DMs even if it looks like a comment', () => {
    const p = socialRowProps({ ...baseDm, snippet: "Comment: 'not unwrapped for dm'" });
    expect(p.preview).toBe("Comment: 'not unwrapped for dm'");
  });

  it('strips a "<surface>:" prefix from Meta sender identifiers', () => {
    const p = socialRowProps({ ...baseDm, from_address: 'whatsapp:15551234567', channel: META_CHANNEL.WHATSAPP });
    expect(p.sender).toBe('15551234567');
  });

  it('falls back to provider type when channel is absent, and to dm kind', () => {
    const p = socialRowProps({ ...baseDm, channel: null, kind: null });
    expect(p.channel).toBe('instagram');
    expect(p.kind).toBe(META_KIND.DM);
  });
});
