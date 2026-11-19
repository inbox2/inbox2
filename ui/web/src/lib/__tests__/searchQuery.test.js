import { describe, it, expect } from 'vitest';
import { parse, format, isBare, chips, without, parseSize, toSqlite, toApiParams } from '../searchQuery';

describe('searchQuery parse/format', () => {
  it('keeps unrecognised text as free text', () => {
    const q = parse('deliveroo receipt');
    expect(q.text).toBe('deliveroo receipt');
    expect(isBare(q)).toBe(true);
  });

  it('reads operators and leaves the rest as text', () => {
    const q = parse('invoice from:ana has:attachment in:anywhere larger:5mb before:2026-01-31');
    expect(q).toMatchObject({
      text: 'invoice',
      from: ['ana'],
      is: ['attachment'],
      in: 'anywhere',
      larger: 5_000_000,
      before: '2026-01-31',
    });
    expect(isBare(q)).toBe(false);
  });

  it('takes quoted values and repeats a field', () => {
    const q = parse('from:"Ana Lee" from:bob subject:"q3 planning"');
    expect(q.from).toEqual(['Ana Lee', 'bob']);
    expect(q.subject).toEqual(['q3 planning']);
  });

  it('treats an unknown operator as text, not a silent drop', () => {
    const q = parse('colour:red is:sideways hello');
    expect(q.text).toBe('colour:red is:sideways hello');
    expect(q.is).toEqual([]);
  });

  it('round-trips through format', () => {
    const original = 'invoice from:"Ana Lee" cc:bob has:attachment in:trash larger:5mb after:2026-01-01';
    expect(format(parse(original))).toBe(original);
  });

  it('parses sizes with and without units', () => {
    expect(parseSize('5mb')).toBe(5_000_000);
    expect(parseSize('500kb')).toBe(500_000);
    expect(parseSize('1.5M')).toBe(1_500_000);
    expect(parseSize('2048')).toBe(2048);
    expect(parseSize('big')).toBeNull();
  });
});

describe('searchQuery chips', () => {
  it('lists every active filter and removes one at a time', () => {
    const q = parse('from:ana from:bob is:unread larger:1mb');
    expect(chips(q).map(c => c.label)).toEqual([
      'from: ana', 'from: bob', 'unread', 'larger than 1mb',
    ]);

    const dropped = without(q, { field: 'from', value: 'ana' });
    expect(dropped.from).toEqual(['bob']);
    expect(without(dropped, { field: 'larger' }).larger).toBeNull();
  });
});

describe('searchQuery → SQLite', () => {
  it('hides trash and spam unless a scope says otherwise', () => {
    expect(toSqlite(parse('hi')).where.join(' ')).toContain("c.status NOT IN ('trash', 'spam')");
    expect(toSqlite(parse('hi in:anywhere')).where.join(' ')).not.toContain('NOT IN');
    const trashOnly = toSqlite(parse('hi in:trash'));
    expect(trashOnly.where.join(' ')).toContain('c.status IN');
    expect(trashOnly.params).toContain('trash');
  });

  it('binds address filters as case-insensitive substrings', () => {
    const { where, params } = toSqlite(parse('from:Ana cc:bob'), 3);
    expect(where[0]).toBe('(LOWER(m.from_address) LIKE ?3)');
    expect(where[1]).toBe('(LOWER(m.cc_address) LIKE ?4)');
    expect(params).toEqual(['%ana%', '%bob%']);
  });

  it('maps size to the message\'s largest attachment', () => {
    const { where, params } = toSqlite(parse('larger:5mb'), 1);
    expect(where[0]).toBe('m.attachment_max_size > ?1');
    expect(params).toEqual([5_000_000]);
  });

  it('matches a file type on the filename extension', () => {
    const { where, params } = toSqlite(parse('type:pdf type:.docx'), 1);
    expect(where[0]).toBe('(LOWER(m.attachment_names) LIKE ?1 OR LOWER(m.attachment_names) LIKE ?2)');
    expect(params).toEqual(['%.pdf%', '%.docx%']);
  });

  it('maps read state and attachment presence to conversation columns', () => {
    expect(toSqlite(parse('is:unread has:attachment')).where).toEqual(
      expect.arrayContaining(['c.read = 0', 'c.has_attachment = 1', expect.stringContaining('NOT IN')])
    );
  });
});

describe('searchQuery → API params', () => {
  it('sends operators as their own params, free text stays out', () => {
    expect(toApiParams(parse('invoice from:ana from:bob is:unread in:archive larger:5mb'))).toEqual({
      from: 'ana,bob',
      is: 'unread',
      in: 'archive',
      larger: 5_000_000,
    });
  });

  it('sends nothing for a bare query', () => {
    expect(toApiParams(parse('just words'))).toEqual({});
  });
});
