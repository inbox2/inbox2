import { describe, it, expect, vi, afterEach } from 'vitest';
import { scrub } from '../demoData';

// The mapping is salted per demo session (so a screenshot isn't a membership
// oracle). These tests pin one salt so expectations stay stable.
vi.stubGlobal('sessionStorage', { getItem: () => 'test-salt', setItem: () => {}, removeItem: () => {} });
afterEach(() => { /* salt is module-cached on purpose — one per session */ });

describe('demo data scrub', () => {
  it('rewrites addresses, names, subjects and bodies', () => {
    const [row] = scrub([{
      key: 'conv_abc',
      from_address: 'Jan Modaal <jan@realcompany.nl>',
      subject: 'Herinnering: factuur 2026-0091',
      snippet: 'Beste Jan, bijgaand de factuur voor september.',
      read: 0,
      updated_at: '2026-09-18T08:00:00Z',
    }]);

    expect(row.from_address).not.toContain('realcompany.nl');
    expect(row.from_address).toMatch(/^.+ <[^@]+@[^>]+>$/);
    expect(row.subject).not.toContain('factuur');
    expect(row.snippet).not.toContain('Beste Jan');
    // Identity, state and timestamps are the shape of the demo — never touched.
    expect(row.key).toBe('conv_abc');
    expect(row.read).toBe(0);
    expect(row.updated_at).toBe('2026-09-18T08:00:00Z');
  });

  it('maps one real address to the same fake person everywhere', () => {
    const a = scrub({ from_address: 'sam@realcompany.nl' }).from_address;
    const b = scrub({ to_address: 'Sam <sam@realcompany.nl>' }).to_address;
    expect(b).toContain(a);
    expect(a).not.toBe(scrub({ from_address: 'other@realcompany.nl' }).from_address);
  });

  it('agrees on name and address within one row', () => {
    const row = scrub({ email: 'sam@realcompany.nl', name: 'Sam Jansen' });
    const listed = scrub({ from_address: 'Sam Jansen <sam@realcompany.nl>' }).from_address;
    expect(row.name).not.toBe('Sam Jansen');
    // Same person, whether the name came from a field or from inside the address.
    expect(listed).toBe(`${row.name} <${row.email}>`);
  });

  it('leaves folder, tag and Space names alone', () => {
    // No address in the object → "name" is not a person.
    expect(scrub({ name: 'Archive', slug: 'archive' }).name).toBe('Archive');
    expect(scrub([{ name: 'Finance', key: 'spc_1' }])[0].name).toBe('Finance');
  });

  it('turns a bare domain into a fake domain, not a person', () => {
    const tab = scrub({ email_address: 'realcompany.nl', display_name: 'realcompany.nl' });
    expect(tab.email_address).toMatch(/^[a-z0-9-]+\.[a-z.]+$/);
    expect(tab.display_name).toBe(tab.email_address);
  });

  it('scrubs a real name even when the address beside it is already fake', () => {
    // A row can arrive half-scrubbed. Passing the display name through because
    // "the address is already one of ours" leaked the real name.
    const out = scrub({ from_address: 'Jan Modaal <sarah.chen@northwind.io>' }).from_address;
    expect(out).not.toContain('Jan Modaal');
    expect(out).toMatch(/^.+ <[^@]+@[^>]+>$/);
  });

  it('scrubs a real value that happens to match the generated cast', () => {
    // "Sarah Chen" is a name real people have. Exempting values that look like
    // ours sent hers straight to the screenshot.
    const row = scrub({ name: 'Sarah Chen', email: 'sarah.chen@northwind.io' });
    // Re-derived from the address it sits beside, not passed through because it
    // looked like one of ours.
    const sameAddress = scrub({ name: 'Someone Else', email: 'sarah.chen@northwind.io' });
    expect(row.name).toBe(sameAddress.name);
    expect(row.email).toBe(sameAddress.email);
  });

  it('renames the organisation, not folders or Spaces', () => {
    const org = scrub({ name: 'Acme BV', domain: 'acme.nl', slug: 'acme-bv' });
    expect(org.name).not.toBe('Acme BV');
    // Workspace name and its domain tell one story.
    expect(org.domain.startsWith(org.name.toLowerCase().replace(/[^a-z]/g, '').slice(0, 5))).toBe(true);
    // A Space or folder has no domain beside it and keeps its name.
    expect(scrub({ name: 'Finance', key: 'spc_1' }).name).toBe('Finance');
  });

  it('scrubs inside a JSON blob column (calendar attendees)', () => {
    // calendar_events.metadata is a JSON *string*: the attendee list and the
    // conference link hide in there, past every field-name rule.
    const row = scrub({
      title: 'Kwartaalgesprek',
      metadata: JSON.stringify({ attendees: [{ email: 'piet@realcompany.nl', name: 'Piet' }] }),
    });
    const meta = JSON.parse(row.metadata);
    expect(meta.attendees[0].email).not.toContain('realcompany.nl');
    expect(meta.attendees[0].name).not.toBe('Piet');
  });

  it('leaves a non-JSON blob field exactly as it is', () => {
    expect(scrub({ metadata: 'not json' }).metadata).toBe('not json');
  });

  it('keeps a quoted display name whole — "Doe, Jane" is one recipient', () => {
    // Splitting on every comma left the bare `"Doe` fragment untouched (no '@',
    // so no rule claimed it) — a real surname, in plain sight.
    const out = scrub({ to_address: '"Doe, Jane" <jane@realcompany.nl>, bob@realcompany.nl' }).to_address;
    expect(out).not.toMatch(/Doe/);
    expect(out).not.toContain('realcompany.nl');
    expect(out.split(', ')).toHaveLength(2);
  });

  it('agrees on the person when the address field carries a display name', () => {
    // `from_address` is usually `Name <addr>`; seeding the name off the whole
    // string picked a different person than the address itself resolved to.
    const row = scrub({ from_address: 'Jan Modaal <jan@realcompany.nl>', name: 'Jan Modaal' });
    expect(row.from_address).toBe(`${row.name} <${row.from_address.match(/<(.+)>/)[1]}>`);
  });

  it('replaces a real conference link wherever it hides', () => {
    const row = scrub({
      metadata: JSON.stringify({ conference: { url: 'https://meet.google.com/real-live-call' } }),
      hangout_link: 'https://teams.microsoft.com/l/meetup-join/19%3areal',
    });
    expect(row.hangout_link).not.toContain('19%3areal');
    expect(JSON.parse(row.metadata).conference.url).not.toContain('real-live-call');
  });

  it('drops real logos and profile pictures', () => {
    const row = scrub({ name: 'Finance', icon_url: 'https://cdn.realcompany.nl/logo.png', avatar_url: 'https://x/y.jpg' });
    expect(row.icon_url).toBeNull();
    expect(row.avatar_url).toBeNull();
  });

  it('re-salts each demo session, so a screenshot is not a lookup table', async () => {
    // Without a per-session salt the mapping is a fixed function of the address:
    // anyone with a guessed address could hash it and check whether its stand-in
    // appears in a published screenshot.
    const mapWithSalt = async (value) => {
      vi.stubGlobal('sessionStorage', { getItem: () => value, setItem: () => {}, removeItem: () => {} });
      vi.resetModules();
      const fresh = await import('../demoData');
      return ['a@realcompany.nl', 'b@realcompany.nl', 'c@realcompany.nl', 'd@realcompany.nl']
        .map((e) => fresh.scrub({ from_address: e }).from_address);
    };
    expect(await mapWithSalt('salt-A')).not.toEqual(await mapWithSalt('salt-B'));
  });

  it('pairs the body with the subject, and previews with both', () => {
    // A screenshot shows subject and body together: an invoice subject over
    // three paragraphs about a pilot timeline reads as obviously generated.
    const conv = scrub({ subject: 'Herinnering: factuur', snippet: 'Beste Jan, hierbij' });
    const reply = scrub({ subject: 'Re: Herinnering: factuur', body_plain: 'echte tekst' });
    expect(reply.subject).toBe(`Re: ${conv.subject}`);          // same thread
    expect(reply.body_plain.startsWith(conv.snippet)).toBe(true); // preview = first sentence
  });

  it('gives bodies real paragraphs — and HTML bodies real markup', () => {
    const row = scrub({ subject: 'x', body_plain: 'one liner', body_html: '<p>one liner</p>' });
    expect(row.body_plain.split('\n\n').length).toBeGreaterThan(1);
    expect(row.body_html).toMatch(/^<p>[\s\S]+<\/p>$/);
    expect(row.body_html).not.toContain('\n\n');
  });

  it('recurses through nested API payloads', () => {
    const out = scrub({
      conversations: [{ messages: [{ from_address: 'a@realcompany.nl', body_plain: 'secret' }] }],
    });
    expect(out.conversations[0].messages[0].body_plain).not.toBe('secret');
  });
});
