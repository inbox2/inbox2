// localData against REAL SQLite and the engine's real schema file — the point of
// this module is its SQL (json_extract / json_each over `payload`), and a mocked
// db would only test that the mock was called. node:sqlite stands in for
// @tauri-apps/plugin-sql (same `select(sql, binds)` contract).
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const SCHEMA = readFileSync(new URL('../../../../desktop/core/migrations/001_create_schema.sql', import.meta.url), 'utf8');
const ORG = 'org_a';
let db;
let demo = false;

let signedInAs = 'usr_1';
vi.mock('../tauri.js', () => ({ isTauri: () => true }));
vi.mock('../mxMirror.js', () => ({ default: { get userKey() { return signedInAs; } } }));
vi.mock('../demoData.js', () => ({
  isDemoMode: () => demo,
  scrubIfDemo: (v) => (demo ? v.map(x => ({ ...x, subject: 'SCRUBBED' })) : v),
}));
vi.mock('../db.js', () => ({
  getDb: async () => ({ select: async (sql, binds = []) => db.prepare(sql).all(...binds) }),
}));

const conv = (id, extra = {}) => ({
  id, status: 'open', read: false, subject: `Subject ${id}`, domain_id: 'dom_1',
  updated_at: '2026-09-20T10:00:00Z', tags: [], assignees: [], space: null, change_seq: 1, ...extra,
});

function hold(c, { hydrated = 1, org = ORG } = {}) {
  db.prepare(`INSERT INTO mx_conversations (key, organization_id, domain_key, status, read, subject, from_address,
      to_address, space_slug, updated_at, change_seq, hydrated, payload)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(c.id, org, c.domain_id, c.status, c.read ? 1 : 0, c.subject, c.from_address ?? null,
      c.to_address ?? null, c.space?.slug ?? null, c.updated_at, c.change_seq, hydrated, JSON.stringify(c));
}

function mirror({ done = 1, org = ORG, slug = 'acme' } = {}) {
  db.prepare('INSERT INTO mx_sync_state (organization_id, user_key, backfill_done) VALUES (?, ?, ?)').run(org, 'usr_1', done);
  db.prepare(`INSERT INTO mx_directory (organization_id, type, key, position, payload) VALUES (?, 'organization', ?, 0, ?)`)
    .run(org, org, JSON.stringify({ id: org, slug }));
}

const load = async () => { vi.resetModules(); return import('../localData.js'); };
const ids = (r) => r.conversations.map(c => c.id);

beforeEach(() => {
  demo = false;
  signedInAs = 'usr_1';
  db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys = ON'); // the engine's connection sets this; cascades depend on it
  db.exec(SCHEMA);
});

describe('localData — MX reads from the mirror', () => {
  it('answers by org key or slug, and only once history is complete', async () => {
    const { getConversations } = await load();
    expect(await getConversations(ORG, {})).toBeNull(); // not mirrored at all

    mirror({ done: 0 });
    hold(conv('conv_1'));
    expect(await getConversations(ORG, {})).toBeNull(); // a partial page would silently miss mail

    db.exec('UPDATE mx_sync_state SET backfill_done = 1');
    expect(ids(await getConversations(ORG, {}))).toEqual(['conv_1']);
    expect(ids(await getConversations('acme', {}))).toEqual(['conv_1']);
  });

  it('returns the API payload verbatim — and an empty list, not null, when nothing matches', async () => {
    const { getConversations } = await load();
    mirror();
    const c = conv('conv_1', { tags: [{ id: 'tag_1', name: 'Urgent' }] });
    hold(c);
    expect((await getConversations(ORG, {})).conversations[0]).toEqual(c);
    const none = await getConversations(ORG, { status: 'spam' });
    expect(none.conversations).toEqual([]);
    expect(none.meta.total).toBe(0);
  });

  it("applies the API's filters: default hides done mail; status, domain, space, tags, read, to/from", async () => {
    const { getConversations } = await load();
    mirror();
    db.prepare(`INSERT INTO mx_directory (organization_id, type, key, position, payload) VALUES (?, 'domains', 'dom_2', 0, ?)`)
      .run(ORG, JSON.stringify({ id: 'dom_2', slug: 'beta-test', name: 'beta.test' }));
    hold(conv('open_1', { updated_at: '2026-09-20T12:00:00Z' }));
    hold(conv('archived', { status: 'archived' }));
    hold(conv('beta', { domain_id: 'dom_2', read: true, to_address: 'team@beta.test', from_address: 'bob@x.test' }));
    hold(conv('sales', { space: { id: 'spc_1', slug: 'sales' }, tags: [{ name: 'Urgent' }, { name: 'VIP' }] }));

    expect(ids(await getConversations(ORG, {})).sort()).toEqual(['beta', 'open_1', 'sales']);
    expect(ids(await getConversations(ORG, { status: 'archived' }))).toEqual(['archived']);
    for (const domain of ['dom_2', 'beta-test', 'beta.test']) {
      expect(ids(await getConversations(ORG, { domain }))).toEqual(['beta']);
    }
    expect(ids(await getConversations(ORG, { space: 'spc_1' }))).toEqual(['sales']);
    expect(ids(await getConversations(ORG, { tags: ['Later', 'VIP'] }))).toEqual(['sales']);
    expect(ids(await getConversations(ORG, { read: 'true' }))).toEqual(['beta']);
    expect(ids(await getConversations(ORG, { to: 'team@beta.test', from: 'bob@x.test' }))).toEqual(['beta']);
  });

  it('pages newest-first with the meta the list UI reads', async () => {
    const { getConversations } = await load();
    mirror();
    for (let i = 1; i <= 5; i++) hold(conv(`conv_${i}`, { updated_at: `2026-09-2${i}T10:00:00Z` }));
    const p1 = await getConversations(ORG, { per_page: 2 });
    const p3 = await getConversations(ORG, { per_page: 2, page: 3 });
    expect(ids(p1)).toEqual(['conv_5', 'conv_4']);
    expect(ids(p3)).toEqual(['conv_1']);
    expect(p1.meta).toEqual({ page: 1, per_page: 2, total: 5, total_pages: 3 });
  });

  it('leaves server-only filters to the API', async () => {
    const { getConversations } = await load();
    mirror();
    hold(conv('conv_1'));
    for (const params of [{ view_id: 'v' }, { direction: 'outbound' }, { is_draft: 'true' }, { mentioned: 'me' }, { assignee: 'me' }]) {
      expect(await getConversations(ORG, params)).toBeNull();
    }
  });

  it('never returns another org\'s mail', async () => {
    const { getConversations, getConversation } = await load();
    mirror();
    mirror({ org: 'org_b', slug: 'other' });
    hold(conv('conv_b'), { org: 'org_b' });
    expect(ids(await getConversations(ORG, {}))).toEqual([]);
    expect(await getConversation(ORG, 'conv_b')).toBeNull();
  });

  it('assembles a thread like conversations#show, with full assignee records', async () => {
    const { getConversation } = await load();
    mirror();
    hold(conv('conv_1', { assignees: [{ id: 'mem_1', name: 'Ann' }, { id: 'mem_gone', name: 'Zed' }] }));
    const put = (table, id, at) => db.prepare(
      `INSERT INTO ${table} (key, conversation_key, organization_id, created_at, payload) VALUES (?, 'conv_1', ?, ?, ?)`)
      .run(id, ORG, at, JSON.stringify({ id }));
    put('mx_messages', 'msg_2', '2026-09-20T11:00:00Z');
    put('mx_messages', 'msg_1', '2026-09-20T10:00:00Z');
    put('mx_notes', 'note_1', '2026-09-20T10:30:00Z');
    db.prepare(`INSERT INTO mx_directory (organization_id, type, key, position, payload) VALUES (?, 'members', 'mem_1', 0, ?)`)
      .run(ORG, JSON.stringify({ id: 'mem_1', role: 'admin', user: { display_name: 'Ann A' } }));

    const { conversation } = await getConversation(ORG, 'conv_1');
    expect(conversation.messages.map(m => m.id)).toEqual(['msg_1', 'msg_2']);
    expect(conversation.notes.map(n => n.id)).toEqual(['note_1']);
    expect(conversation.assignees).toEqual([
      { id: 'mem_1', role: 'admin', user: { display_name: 'Ann A' } },
      { id: 'mem_gone', name: 'Zed' }, // not in the directory: keep what the row said
    ]);
  });

  it('never serves a mirror that was built for another user', async () => {
    const { getConversations, getConversation } = await load();
    mirror();
    hold(conv('conv_1'));
    signedInAs = 'usr_2'; // signed in here before the engine has wiped usr_1's mirror
    expect(await getConversations(ORG, {})).toBeNull();
    expect(await getConversation(ORG, 'conv_1')).toBeNull();
  });

  it('sends a thread it holds only as a list row to the API', async () => {
    const { getConversation } = await load();
    mirror();
    hold(conv('conv_shared'), { hydrated: 0 });
    expect(await getConversation(ORG, 'conv_shared')).toBeNull();
  });

  it('lists the directory in server order', async () => {
    const { getTags, getMembers } = await load();
    mirror();
    const put = (type, key, position) => db.prepare(
      'INSERT INTO mx_directory (organization_id, type, key, position, payload) VALUES (?, ?, ?, ?, ?)')
      .run(ORG, type, key, position, JSON.stringify({ id: key }));
    put('tags', 'tag_z', 0); put('tags', 'tag_a', 1);
    expect((await getTags(ORG)).tags.map(t => t.id)).toEqual(['tag_z', 'tag_a']);
    expect((await getMembers(ORG)).members).toEqual([]); // mirrored and empty ≠ unknown
  });

  it('scrubs mirror reads in demo mode — payloads are opaque to the SQL-row scrubber', async () => {
    const { getConversations } = await load();
    mirror();
    hold(conv('conv_1', { subject: 'Acquisition terms — confidential' }));
    demo = true;
    expect((await getConversations(ORG, {})).conversations[0].subject).toBe('SCRUBBED');
  });

  it('searches the engine-maintained full-text index, and odd input is never a syntax error', async () => {
    const { searchLocal, ftsQuery } = await load();
    mirror();
    hold(conv('conv_hit'));
    hold(conv('conv_spam', { status: 'spam' }));
    const put = (id, thread, text) => db.prepare(
      `INSERT INTO mx_messages (key, conversation_key, organization_id, payload, search_text) VALUES (?, ?, ?, '{}', ?)`)
      .run(id, thread, ORG, text);
    put('msg_1', 'conv_hit', 'Quarterly forecast\nThe pipeline numbers look healthy');
    put('msg_2', 'conv_spam', 'pipeline of spam');

    expect(ids(await searchLocal(ORG, 'forecast pipe'))).toEqual(['conv_hit']);
    expect(ids(await searchLocal(ORG, 'absent'))).toEqual([]);
    expect(ftsQuery('  ')).toBeNull();
    for (const odd of ['"', 'AND OR NOT', 'a:b -c (d', '*']) await searchLocal(ORG, odd);

    db.prepare('DELETE FROM mx_conversations WHERE key = ?').run('conv_hit'); // cascades; the index follows
    expect(ids(await searchLocal(ORG, 'pipeline'))).toEqual([]);
  });

  it('resolves a mirrored org for the action queue even mid-backfill', async () => {
    const { mirroredOrg } = await load();
    expect(await mirroredOrg(ORG)).toBeNull();
    mirror({ done: 0 });
    expect(await mirroredOrg('acme')).toBe(ORG);
  });
});
