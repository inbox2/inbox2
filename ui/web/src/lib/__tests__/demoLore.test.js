import { describe, it, expect, vi } from 'vitest';
import { scrub } from '../demoData';
import { LORE_THREADS } from '../demoCorpus';

// One pinned salt, as demoData.test.js does.
vi.stubGlobal('sessionStorage', { getItem: () => 'test-salt', setItem: () => {}, removeItem: () => {} });

describe('demo mode × Lore', () => {
  it('a labelled row becomes a thread of its own label, with its title and amount', () => {
    const out = scrub({
      id: 'conv_1', subject: 'Uw Privium factuur', snippet: 'real snippet', from_address: 'Real <real@privium.nl>',
      triage_label: 'payment_due', next_action_title: 'Pay Schiphol Privium invoice',
      next_action_amount_cents: 12345, next_action_currency: 'EUR',
    });
    const pool = LORE_THREADS.filter((t) => t.label === 'payment_due');
    const t = pool.find((x) => x.subject === out.subject);
    expect(t).toBeTruthy();
    expect(out.next_action_title).toBe(t.title);
    expect(out.next_action_amount_cents).toBe(t.amount_cents);
    expect(out.snippet).not.toBe('real snippet');
    expect(out.from_address).not.toMatch(/privium/);
  });

  it('the thread\'s messages (no label) open as the same stand-in', () => {
    const row = scrub({ subject: 'Herinnering: factuur 991', triage_label: 'payment_due' });
    const msg = scrub({ subject: 'Herinnering: factuur 991', body_plain: 'real body' });
    expect(msg.subject).toBe(row.subject);
    expect(msg.body_plain).not.toBe('real body');
  });

  it('never shows a real AI title on an unlabelled row', () => {
    expect(scrub({ subject: 'x', next_action_title: 'Pay the real vendor' }).next_action_title).toBeNull();
  });

  it('rewrites mined entities and facts', () => {
    const e = scrub({ id: 'ent_1', kind: 'organization', name: 'ALFAHIM', email_domain: 'alfahim.ae' });
    expect(e.name).not.toBe('ALFAHIM');
    expect(e.email_domain).not.toBe('alfahim.ae');
    const p = scrub({ kind: 'project', name: 'VAT report rewrite' });
    expect(p.name).not.toBe('VAT report rewrite');
    const f = scrub({ kind: 'attribute', name: 'role', value: 'Procurement at ALFAHIM', quote: 'Looping in Hamdan from procurement' });
    expect(f.value).not.toMatch(/ALFAHIM/);
    expect(f.quote).not.toMatch(/Hamdan/);
  });
});
