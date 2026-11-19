import { describe, it, expect } from 'vitest';
import {
  bucketFor, toItem, buildToday, urgency, dueLabel, formatAmount, cleanSubject, groupItems, entitiesFrom, orgDomain, searchItems, ageLabel, ageStep, initials,
  LORE_BUCKET, DO_FIRST_COUNT, isMemberDone, groupButton,
} from '../lore';

const mx = (id, label, extra = {}) => ({
  id, subject: id, from_address: 'Rizwan <rizwan@tuli.com>', updated_at: '2026-10-19T10:00:00Z',
  read: true, triage_label: label, triage_priority: 2, ...extra,
});

describe('bucketFor', () => {
  it('maps built-ins, drops resolved and untriaged, sends custom labels to work', () => {
    expect(bucketFor('payment_due')).toBe(LORE_BUCKET.PAY);
    expect(bucketFor('needs_answer')).toBe(LORE_BUCKET.REPLY);
    expect(bucketFor('needs_answer_other')).toBe(LORE_BUCKET.WAITING);
    expect(bucketFor('notification')).toBe(LORE_BUCKET.HANDLED);
    expect(bucketFor('resolved')).toBeNull();
    expect(bucketFor(null)).toBeNull();
    expect(bucketFor('legal_review')).toBe(LORE_BUCKET.WORK);
  });
});

describe('orgDomain', () => {
  it('keeps the registrable domain and ignores freemail', () => {
    expect(orgDomain('Odido <noreply@mail.odido.nl>')).toBe('odido.nl');
    expect(orgDomain('x@billing.acme.co.uk')).toBe('acme.co.uk');
    expect(orgDomain('Ali <ali@gmail.com>')).toBeNull();
    expect(orgDomain('')).toBeNull();
  });
});

describe('toItem', () => {
  it('routes MX items by org and local ones by account, and names custom labels', () => {
    const a = toItem(mx('conv_1', 'payment_due'), { source: 'mx', orgId: 'org_1' });
    expect(a).toMatchObject({ uid: 'mx:conv_1', orgId: 'org_1', accountKey: null, bucket: 'pay', domain: 'tuli.com', from: 'Rizwan' });
    const b = toItem({ key: 'k1', account_key: 'acc_1', triage_label: 'legal_review', read: 0, from_address: 'x@y.com' },
      { source: 'local', labels: [{ slug: 'legal_review', name: 'Legal review' }] });
    expect(b).toMatchObject({ uid: 'local:k1', accountKey: 'acc_1', orgId: null, unread: true, labelName: 'Legal review', priority: -1 });
    expect(toItem(mx('conv_2', 'resolved'), { source: 'mx' })).toBeNull();
  });
});

describe('buildToday', () => {
  it('ranks do-first from action buckets only and does not repeat them below', () => {
    const items = [
      toItem(mx('pay-high', 'payment_due', { triage_priority: 3.9 }), { source: 'mx' }),
      toItem(mx('read-top', 'read_later', { triage_priority: 4 }), { source: 'mx' }),
      toItem(mx('reply', 'needs_answer', { triage_priority: 3 }), { source: 'mx' }),
      toItem(mx('work', 'action_required', { triage_priority: 2.5 }), { source: 'mx' }),
      toItem(mx('meet', 'scheduling', { triage_priority: 1 }), { source: 'mx' }),
      toItem(mx('fyi', 'fyi'), { source: 'mx' }),
      toItem(mx('otp', 'notification'), { source: 'mx' }),
    ];
    const t = buildToday(items);
    expect(t.first.map((g) => g.lead.id)).toEqual(['pay-high', 'reply', 'work']);
    expect(t.first).toHaveLength(DO_FIRST_COUNT);
    const ids = t.sections.flatMap((s) => s.items.map((i) => i.id));
    expect(ids).toEqual(expect.arrayContaining(['read-top', 'meet']));
    expect(ids).not.toContain('pay-high');
    expect(t.handled.find((g) => g.label === 'fyi').items).toHaveLength(1);
    expect(t.handled.find((g) => g.label === 'notification').items).toHaveLength(1);
    expect(t.open).toBe(5);
  });
});

describe('entitiesFrom', () => {
  it('groups orgs by domain and people by address, most items first', () => {
    const items = [
      toItem(mx('a', 'needs_answer'), { source: 'mx' }),
      toItem(mx('b', 'payment_due', { from_address: 'Chadi <chadi@tuli.com>' }), { source: 'mx' }),
      toItem(mx('c', 'payment_due', { from_address: 'billing@odido.nl' }), { source: 'mx' }),
    ];
    const { orgs, people } = entitiesFrom(items);
    expect(orgs[0]).toMatchObject({ domain: 'tuli.com', name: 'Tuli', count: 2, people: 2 });
    expect(orgs[1].domain).toBe('odido.nl');
    expect(people).toHaveLength(3);
  });
});

describe('searchItems / ageLabel / initials', () => {
  it('filters across fields and formats ages and initials', () => {
    const items = [toItem(mx('VAT report', 'action_required'), { source: 'mx' }), toItem(mx('Lunch', 'scheduling'), { source: 'mx' })];
    expect(searchItems(items, 'vat').map((i) => i.id)).toEqual(['VAT report']);
    expect(searchItems(items, 'tuli.com')).toHaveLength(2);
    expect(searchItems(items, '')).toHaveLength(2);
    const now = Date.parse('2026-10-20T12:00:00Z');
    expect(ageLabel(now - 2 * 86400000, now)).toBe('2 days');
    // Calendar days: late on the 7th to early on the 10th is 3 days, not 2.
    const tenth = new Date(2026, 10, 10, 9, 0).getTime();
    expect(ageLabel(new Date(2026, 10, 7, 11, 0).getTime(), tenth)).toBe('3 days');
    expect(ageLabel(new Date(2026, 10, 9, 23, 30).getTime(), tenth)).toBe('yesterday');
    expect(ageLabel(now - 15 * 86400000, now)).toBe('2 weeks');
    expect(initials('Ali Khan')).toBe('AK');
    expect(initials('')).toBe('?');
  });
});

describe('next-action fields and ranking', () => {
  const now = new Date(2026, 9, 20, 12).getTime();
  it('parses due date and amount', () => {
    const i = toItem(mx('bill', 'payment_due', { next_action_due_on: '2026-10-22', next_action_amount_cents: 38600, next_action_currency: 'EUR' }), { source: 'mx' });
    expect(new Date(i.dueAt).getDate()).toBe(22);
    expect(i.amount).toMatch(/386/);
    expect(dueLabel(i.dueAt, now)).toBe('in 2 days');
    expect(dueLabel(new Date(2026, 9, 19).getTime(), now)).toBe('overdue');
    expect(formatAmount(null, 'EUR')).toBeNull();
    expect(toItem(mx('x', 'needs_answer'), { source: 'mx' }).dueAt).toBeNull();
  });
  it('lets a near deadline outrank a slightly higher priority', () => {
    const soon = toItem(mx('soon', 'payment_due', { triage_priority: 2.5, next_action_due_on: '2026-10-21' }), { source: 'mx' });
    const high = toItem(mx('high', 'needs_answer', { triage_priority: 3 }), { source: 'mx' });
    expect(urgency(soon, now)).toBe(3.5);
    expect(buildToday([high, soon], now).first.map((g) => g.lead.id)).toEqual(['soon', 'high']);
  });
});

describe('titles and grouping', () => {
  it('cleans reply and reminder prefixes, and prefers the AI title', () => {
    expect(cleanSubject('RE: Herinnering: Privium Members Club factuur')).toBe('Privium Members Club factuur');
    expect(cleanSubject('Fwd: [Action Required] - AWS account alert')).toBe('AWS account alert');
    expect(cleanSubject('2e herinnering openstaande factuur')).toBe('Openstaande factuur');
    const ai = toItem(mx('a', 'payment_due', { next_action_title: 'Pay Schiphol Privium invoice' }), { source: 'mx' });
    expect(ai.title).toBe('Pay Schiphol Privium invoice');
    expect(toItem(mx('Herinnering: factuur 1', 'payment_due'), { source: 'mx' })).toMatchObject({ title: 'Factuur 1', reminder: true });
  });
  it('groups an invoice and its reminder from one sender, shows one amount only when they agree', () => {
    const inv = toItem(mx('Uw Privium factuur', 'payment_due', { from_address: 'x@privium.nl', next_action_amount_cents: 10000, next_action_currency: 'EUR', next_action_due_on: '2026-11-01' }), { source: 'mx' });
    const rem = toItem(mx('Herinnering: Privium factuur', 'payment_due', { from_address: 'y@privium.nl', triage_priority: 3, next_action_amount_cents: 5000, next_action_currency: 'EUR', next_action_due_on: '2026-10-25' }), { source: 'mx' });
    const other = toItem(mx('Odido bill', 'payment_due', { from_address: 'b@odido.nl' }), { source: 'mx' });
    const oct = toItem(mx('Factuur oktober 2026', 'payment_due', { from_address: 'a@ally.nl' }), { source: 'mx' });
    const nov = toItem(mx('Factuur november 2026', 'payment_due', { from_address: 'a@ally.nl' }), { source: 'mx' });
    const num1 = toItem(mx('factuurnummer 1186795 (Dossier 55)', 'payment_due', { from_address: 'f@moller.nl' }), { source: 'mx' });
    const num2 = toItem(mx('Openstaande factuur 1186795', 'payment_due', { from_address: 'd@moller.nl' }), { source: 'mx' });
    const unrelatedReminder = toItem(mx('Herinnering: parkeerabonnement', 'payment_due', { from_address: 'z@privium.nl' }), { source: 'mx' });
    expect(groupItems([rem, inv, unrelatedReminder]).map((g) => g.items.length)).toEqual([2, 1]);
    const groups = groupItems([rem, inv, other, oct, nov, num1, num2]);
    expect(groups.map((g) => g.items.length)).toEqual([2, 1, 1, 1, 2]); // Privium pair, Odido, Ally ×2 apart, Moller by number
    expect(groups[0].items.map((i) => i.id)).toEqual(['Herinnering: Privium factuur', 'Uw Privium factuur']);
    expect(groups[0].total).toBeNull(); // 100 vs 50: not summed, not guessed
    const rem2 = { ...rem, amountCents: 10000 };
    expect(groupItems([rem2, inv])[0].total).toMatch(/100/);
    const a = toItem(mx('Invoice', 'payment_due', { from_address: 'x@acme.com' }), { source: 'mx' });
    const b = toItem(mx('Invoice', 'payment_due', { from_address: 'y@acme.com', id: 'b' }), { source: 'mx' });
    expect(groupItems([a, { ...b, uid: 'b' }]).length).toBe(2); // same generic subject: two invoices
    expect(new Date(groups[0].dueAt).getDate()).toBe(25);
    expect(groups[1].total).toBeNull();
    expect(groups[4].items.map((i) => i.id)).toEqual(['factuurnummer 1186795 (Dossier 55)', 'Openstaande factuur 1186795']);
  });
});

import { dominantColor } from '../brandColor';
describe('dominantColor', () => {
  const px = (rgba, n) => Array.from({ length: n }, () => rgba).flat();
  it('picks the colourful hue and ignores white, black and grey', () => {
    const data = new Uint8ClampedArray([...px([255, 255, 255, 255], 40), ...px([20, 20, 20, 255], 30), ...px([255, 103, 25, 255], 20), ...px([128, 128, 128, 255], 30)]);
    expect(dominantColor(data)).toBe('#ff6719');
  });
  it('returns null for a greyscale logo', () => {
    expect(dominantColor(new Uint8ClampedArray([...px([0, 0, 0, 255], 50), ...px([255, 255, 255, 255], 50)]))).toBeNull();
  });
});

describe('ageStep', () => {
  const now = Date.UTC(2026, 9, 20);
  const ago = (d) => now - d * 86400000;
  it('fades with age', () => {
    expect([0.5, 3, 10, 40, 90].map((d) => ageStep(ago(d), now))).toEqual([0, 1, 2, 3, 4]);
    expect(ageStep(null, now)).toBe(4);
  });
});

import { waTodoItem, waGroupsFrom, entitiesFrom as entitiesOf, LORE_BUCKET as BUCKET } from '../lore';

describe('tracked WhatsApp group to-dos', () => {
  const row = (over) => ({ id: 1, chat_id: 1145, chat_name: 'BlueOcean x TULI', title: 'Send demo dates', summary: 'For the one-hour demo', owner: 'Mo', mine: 0, from_id: 124497, at: '2026-10-26T10:00:00Z', status: 'open', ...over });

  it('puts the owner’s own under work and everyone else’s under waiting', () => {
    const theirs = waTodoItem(row());
    expect(theirs.bucket).toBe(BUCKET.WAITING);
    expect(theirs.from).toBe('Mo');
    expect(theirs).toMatchObject({ chatId: 1145, askId: 124497, todoId: 1, mine: false, group: { chatId: 1145, name: 'BlueOcean x TULI' } });
    const mine = waTodoItem(row({ id: 2, mine: 1, owner: 'You' }));
    expect(mine.bucket).toBe(BUCKET.WORK);
    expect(mine.mine).toBe(true);
    expect(mine.uid).not.toBe(theirs.uid);
  });

  it('lists each tracked group once with its open count', () => {
    const items = [waTodoItem(row()), waTodoItem(row({ id: 2 })), waTodoItem(row({ id: 3, chat_id: 9, chat_name: 'Acme' }))];
    expect(waGroupsFrom(items)).toEqual([
      { chatId: 1145, name: 'BlueOcean x TULI', count: 2 },
      { chatId: 9, name: 'Acme', count: 1 },
    ]);
    expect(entitiesOf(items).groups).toHaveLength(2);
  });
});


describe('per-member done (48.11)', () => {
  const item = (source, label) => ({ source, label });
  it('is the member\'s own only for personal buckets on shared-domain mail', () => {
    expect(isMemberDone(item('mx', 'fyi'))).toBe(true);
    expect(isMemberDone(item('mx', 'read_later'))).toBe(true);
    expect(isMemberDone(item('mx', 'action_required'))).toBe(false);
    expect(isMemberDone(item('local', 'fyi'))).toBe(false);
  });
  it('says Hide when a Handled group only hides, the group\'s verb otherwise', () => {
    const g = { button: 'Delete', items: [item('mx', 'notification')] };
    expect(groupButton(g)).toBe('Hide');
    expect(groupButton({ ...g, items: [item('mx', 'notification'), item('local', 'notification')] })).toBe('Delete');
  });
});
