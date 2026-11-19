import { describe, it, expect } from 'vitest';
import { conversationItemProps } from '../itemProps';

const baseConv = {
  id: 'conv_1',
  from_address: 'Ada Lovelace <ada@example.com>',
  subject: 'Re: Fwd: Quarterly report',
  snippet: 'Here are the numbers',
  updated_at: '2026-01-15T10:00:00Z',
  read: false,
  tags: [{ name: 'Important', color: '#f00' }],
  assignees: [{ username: 'grace' }],
  message_count: 3,
  has_attachment: true,
};

describe('conversationItemProps', () => {
  it('maps a conversation record to ConversationItem props', () => {
    const p = conversationItemProps(baseConv);
    expect(p.sender).toBe('Ada Lovelace');
    expect(p.subject).toBe('Quarterly report'); // Re:/Fwd: stripped
    expect(p.snippet).toBe('Here are the numbers');
    expect(p.unread).toBe(true);
    expect(p.tags).toEqual([{ name: 'Important', bg: '#f00' }]);
    expect(p.assignee).toBe('grace');
    expect(p.count).toBe(3);
    expect(p.hasAttachment).toBe(true);
    expect(p.quadrant).toBeDefined();
  });

  it('applies fallbacks for missing/empty fields', () => {
    const p = conversationItemProps({
      id: 'conv_2',
      from_address: '',
      subject: '',
      updated_at: '2026-01-15T10:00:00Z',
      read: true,
    });
    expect(p.subject).toBe('(no subject)');
    expect(p.snippet).toBe('');
    expect(p.unread).toBe(false);
    expect(p.count).toBe(1); // message_count missing → 1
    expect(p.tags).toBeUndefined();
    expect(p.assignee).toBeUndefined();
    expect(p.hasAttachment).toBeUndefined();
  });
});
