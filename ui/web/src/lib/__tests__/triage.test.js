import { describe, it, expect } from 'vitest';
import { triageBadge, priorityChip, slugifyTriageLabel, titleCaseSlug, isBuiltinTriageLabel } from '../triage';

describe('triageBadge', () => {
  it('keeps the fixed badge for built-ins and hides the low-signal ones', () => {
    expect(triageBadge('needs_answer')).toEqual({ badge: 'Reply', tone: 'urgent' });
    expect(triageBadge('fyi')).toBeNull();
    expect(triageBadge('resolved')).toBeNull();
    expect(triageBadge(null)).toBeNull();
  });

  it('names a custom label from the loaded list, with its color', () => {
    const labels = [{ slug: 'legal_review', name: 'Legal', color: 'violet' }];
    expect(triageBadge('legal_review', labels)).toEqual({ badge: 'Legal', tone: 'custom', color: 'violet' });
  });

  it('falls back to the title-cased slug before the list loads', () => {
    expect(triageBadge('legal_review', null)).toEqual({ badge: 'Legal review', tone: 'custom', color: null });
  });
});

describe('priorityChip', () => {
  it('maps the 0–4 score to Urgent ≥ 3.5, High ≥ 2.5, else nothing', () => {
    expect(priorityChip(4)).toEqual({ badge: 'Urgent', tone: 'urgent' });
    expect(priorityChip(3.5)).toEqual({ badge: 'Urgent', tone: 'urgent' });
    expect(priorityChip(3.49)).toEqual({ badge: 'High', tone: 'pending' });
    expect(priorityChip(2.5)).toEqual({ badge: 'High', tone: 'pending' });
    expect(priorityChip(2.49)).toBeNull();
    expect(priorityChip(0)).toBeNull();
    expect(priorityChip(null)).toBeNull();
    expect(priorityChip(undefined)).toBeNull();
  });
});

describe('label slugs', () => {
  it('derives [a-z0-9_]{1,40} from a name', () => {
    expect(slugifyTriageLabel('Legal review!')).toBe('legal_review');
    expect(slugifyTriageLabel('  Über -- VIP  ')).toBe('uber_vip');
    expect(slugifyTriageLabel('x'.repeat(60))).toHaveLength(40);
  });

  it('title-cases a slug and knows the built-ins', () => {
    expect(titleCaseSlug('needs_legal_review')).toBe('Needs legal review');
    expect(isBuiltinTriageLabel('waiting_reply')).toBe(true);
    expect(isBuiltinTriageLabel('legal_review')).toBe(false);
    expect(isBuiltinTriageLabel('toString')).toBe(false);
  });
});
