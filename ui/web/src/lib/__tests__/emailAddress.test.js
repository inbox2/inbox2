import { describe, it, expect } from 'vitest';
import { parseAddress, formatMailbox, displayName, emailOnly, parseAddressList, replyAllRecipients, replyFromAddress } from '../emailAddress';

describe('parseAddress', () => {
  it('parses a quoted display name with a comma', () => {
    expect(parseAddress('"Sadiq, Amina" <amina@x.com>')).toEqual({
      name: 'Sadiq, Amina',
      email: 'amina@x.com',
      explicit: true,
    });
  });

  it('parses an unquoted display name', () => {
    expect(parseAddress('John Doe <john@x.com>')).toEqual({
      name: 'John Doe',
      email: 'john@x.com',
      explicit: true,
    });
  });

  it('derives a name from a bare email', () => {
    expect(parseAddress('jane.roe@x.com')).toEqual({
      name: 'Jane Roe',
      email: 'jane.roe@x.com',
      explicit: false,
    });
  });
});

describe('parseAddressList', () => {
  it('does NOT split a quoted display name containing a comma', () => {
    // The reported bug: "Sadiq, Amina" rendered as two chips ("Sadiq + Amina).
    expect(parseAddressList('"Sadiq, Amina" <amina@x.com>, "Bob" <bob@y.com>')).toEqual([
      { name: 'Sadiq, Amina', email: 'amina@x.com', explicit: true },
      { name: 'Bob', email: 'bob@y.com', explicit: true },
    ]);
  });

  it('splits a plain address list', () => {
    expect(parseAddressList('a@x.com, b@y.com').map(r => r.email)).toEqual([
      'a@x.com',
      'b@y.com',
    ]);
  });

  it('keeps angle-bracket addresses intact', () => {
    expect(parseAddressList('John Doe <john@x.com>, jane@y.com').map(r => r.email)).toEqual([
      'john@x.com',
      'jane@y.com',
    ]);
  });

  it('drops entries with no email and handles empty input', () => {
    expect(parseAddressList('')).toEqual([]);
    expect(parseAddressList(null)).toEqual([]);
    expect(parseAddressList('Just A Name')).toEqual([]);
  });
});

describe('replyAllRecipients', () => {
  it('strips self out of a multi-recipient To line (the reported bug)', () => {
    const msg = {
      from_address: 'Alice <alice@x.com>',
      to_address: 'Waseem <waseem@sadiq.nl>, Bob <bob@y.com>',
    };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl')).toEqual({ to: 'Alice <alice@x.com>, Bob <bob@y.com>', cc: '' });
  });

  it('keeps Cc on Cc, dedupes by email, matches self case-insensitively', () => {
    const msg = {
      from_address: 'Alice <alice@x.com>',
      to_address: 'alice@x.com, WASEEM@sadiq.nl',
      cc_address: 'Bob <bob@y.com>, waseem@sadiq.nl, alice@x.com',
    };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl')).toEqual({ to: 'Alice <alice@x.com>', cc: 'Bob <bob@y.com>' });
  });

  it('keeps a comma in a display name quoted, so the sender stays one recipient', () => {
    const msg = { from_address: '"Veger, Nick" <veger@damste.nl>', to_address: 'info@other.nl' };
    const { to } = replyAllRecipients(msg, 'waseem@sadiq.nl');
    expect(parseAddressList(to).map(a => a.email)).toEqual(['veger@damste.nl', 'info@other.nl']);
  });

  it('treats the alias the mail arrived at as self when the account is not on it', () => {
    const msg = { from_address: '"Veger, Nick" <veger@damste.nl>', to_address: '"info@sadiq.nl" <info@sadiq.nl>' };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl')).toEqual({ to: '"Veger, Nick" <veger@damste.nl>', cc: '' });
  });

  it('drops no one when two same-domain recipients make the alias ambiguous', () => {
    const msg = { from_address: 'v@d.nl', to_address: 'info@sadiq.nl, ali@sadiq.nl' };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl').to).toBe('V <v@d.nl>, Info <info@sadiq.nl>, Ali <ali@sadiq.nl>');
  });

  it('never treats a same-domain sender as self', () => {
    const msg = { from_address: 'ali@sadiq.nl', to_address: 'info@sadiq.nl' };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl').to).toBe('Ali <ali@sadiq.nl>');
  });

  it('keeps a same-domain colleague when the account itself is on the message', () => {
    const msg = { from_address: 'a@x.com', to_address: 'waseem@sadiq.nl, Ali <ali@sadiq.nl>' };
    expect(replyAllRecipients(msg, 'waseem@sadiq.nl').to).toBe('A <a@x.com>, Ali <ali@sadiq.nl>');
  });

  it('round-trips a name with escaped quotes and a comma', () => {
    const name = 'A "B, C"';
    const out = formatMailbox(name, 'a@x.com') + ', b@y.com';
    const list = parseAddressList(out);
    expect(list.map(x => x.email)).toEqual(['a@x.com', 'b@y.com']);
    expect(list[0].name).toBe(name);
    expect(formatMailbox(list[0].name, 'a@x.com')).toBe(formatMailbox(name, 'a@x.com'));
  });

  it('returns empty when the only recipient is self', () => {
    expect(replyAllRecipients({ from_address: 'me@x.com' }, 'me@x.com')).toEqual({ to: '', cc: '' });
  });
});

describe('displayName / emailOnly', () => {
  it('reads name and email of a quoted-comma recipient', () => {
    const addr = '"Sadiq, Amina" <amina@x.com>';
    expect(displayName(addr)).toBe('Sadiq, Amina');
    expect(emailOnly(addr)).toBe('amina@x.com');
  });
});

describe('replyFromAddress', () => {
  const ids = [
    { email: 'waseem@inbox2.com', providerType: 'inbox2', orgId: 'org_a' },
    { email: 'waseem@erip.me', providerType: 'inbox2', orgId: 'org_a' },
    { email: 'waseem@verna.ai', providerType: 'inbox2', orgId: 'org_b' },
    { email: 'waseem@tuli.com', providerType: 'gmail' },
  ];
  it('a channel thread replies from its own account, even with an inbox2 address on Cc', () => {
    const msg = { from_address: 'l@x.nl', to_address: 'list@x.nl', cc_address: 'waseem@inbox2.com' };
    expect(replyFromAddress(msg, ids, 'waseem@tuli.com')).toBe('waseem@tuli.com');
  });
  it('an inbox2 thread picks the domain address it was sent to', () => {
    const msg = { from_address: 'Leonard <l@x.nl>', to_address: 'Waseem@Erip.me', cc_address: 'Mo <mo@x.nl>' };
    expect(replyFromAddress(msg, ids, 'waseem@inbox2.com')).toBe('waseem@erip.me');
  });
  it('keeps the sending address on own mail that Cc\'s another own address', () => {
    const msg = { from_address: 'waseem@erip.me', to_address: 'client@x.nl', cc_address: 'waseem@inbox2.com' };
    expect(replyFromAddress(msg, ids, 'waseem@inbox2.com')).toBe('waseem@erip.me');
  });
  it('never picks another org\'s address', () => {
    const msg = { from_address: 'waseem@verna.ai', to_address: 'waseem@inbox2.com' };
    expect(replyFromAddress(msg, ids, 'waseem@inbox2.com')).toBe('waseem@inbox2.com');
  });
  it('never picks a channel address for an inbox2 thread', () => {
    const msg = { from_address: 'waseem@tuli.com', to_address: 'client@x.nl' };
    expect(replyFromAddress(msg, ids, 'waseem@inbox2.com')).toBe('waseem@inbox2.com');
  });
});

describe('formatMailbox', () => {
  it('quotes names a mailbox list would misread', () => {
    expect(formatMailbox('Doe, John', 'j@x.com')).toBe('"Doe, John" <j@x.com>');
    expect(formatMailbox('Say "hi"', 'j@x.com')).toBe('"Say \\"hi\\"" <j@x.com>');
    expect(formatMailbox('J. Doe', 'j@x.com')).toBe('"J. Doe" <j@x.com>');
    expect(formatMailbox('John Doe', 'j@x.com')).toBe('John Doe <j@x.com>');
    expect(formatMailbox('', 'j@x.com')).toBe('j@x.com');
  });

  it('keeps an explicit name that matches the address', () => {
    expect(parseAddress('"John Doe" <john.doe@x.com>').explicit).toBe(true);
  });
});
