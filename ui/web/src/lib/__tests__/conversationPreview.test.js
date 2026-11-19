import { describe, it, expect } from 'vitest';
import { conversationPreview } from '../conversationPreview';

describe('conversationPreview', () => {
  it('prefers the generated one-liner over the body snippet', () => {
    expect(conversationPreview({
      subject: 'Invoice 4021',
      snippet: 'Dear customer, please find attached',
      ai_summary_short: 'Pay €240 before 3 March',
    })).toBe('Pay €240 before 3 March');
  });

  it('falls back to the snippet until the summary exists', () => {
    expect(conversationPreview({ subject: 'Hi', snippet: 'body text' })).toBe('body text');
    expect(conversationPreview({ subject: 'Hi', snippet: 'body text', ai_summary_short: '  ' })).toBe('body text');
  });

  it('falls back when the summary just echoes the subject (rule/no-model path)', () => {
    expect(conversationPreview({
      subject: 'Your weekly newsletter',
      snippet: 'body text',
      ai_summary_short: 'Your weekly newsletter',
    })).toBe('body text');
    // Truncated echo of a long subject.
    expect(conversationPreview({
      subject: 'Your weekly newsletter from the team about everything',
      snippet: 'body text',
      ai_summary_short: 'Your weekly newsletter from the team…',
    })).toBe('body text');
  });

  it('is empty when neither exists', () => {
    expect(conversationPreview({ subject: 'Hi' })).toBe('');
  });
});
