import { describe, it, expect } from 'vitest';
import { orgListParams, folderView, folderPrefKey, unifiedColumnAccounts } from '../addressFolders';

const base = { perPage: 50, domainFilter: 'dom_a' };

describe('orgListParams', () => {
  it('Inbox sends folder=inbox and open', () => {
    const p = orgListParams({ ...base, activeView: { kind: 'system', name: 'Inbox', filters: [] } });
    expect(p).toMatchObject({ folder: 'inbox', status: 'open', domain: 'dom_a' });
  });

  it('an address folder sends its key and open', () => {
    const view = folderView({ key: 'info', kind: 'shared', address: 'info@a.com', can_reply: false }, 'dom_a');
    expect(orgListParams({ ...base, activeView: view })).toMatchObject({ folder: 'info', status: 'open', domain: 'dom_a' });
  });

  it('Sent, Drafts and All Mail send no folder', () => {
    const sent = orgListParams({ ...base, activeView: { kind: 'system', name: 'Sent', filters: [{ field: 'direction', value: 'outbound' }] } });
    expect(sent.folder).toBeUndefined();
    expect(sent.direction).toBe('outbound');
    const drafts = orgListParams({ ...base, activeView: { kind: 'system', name: 'Drafts', filters: [{ field: 'is_draft', value: 'true' }] } });
    expect(drafts.folder).toBeUndefined();
    const all = orgListParams({ ...base, activeView: { kind: 'system', name: 'All Mail', filters: [] } });
    expect(all.folder).toBeUndefined();
    expect(all.status).toBeUndefined();
  });

  it('a Space drill-down keeps the whole pool', () => {
    const p = orgListParams({ perPage: 50, spaceFilter: 'spc_1', activeView: { kind: 'system', name: 'Inbox', filters: [] } });
    expect(p.folder).toBeUndefined();
    expect(p.space).toBe('spc_1');
  });
});

describe('folderPrefKey', () => {
  it('is "inbox" for Inbox, else the address', () => {
    expect(folderPrefKey({ kind: 'inbox', key: 'inbox' })).toBe('inbox');
    expect(folderPrefKey({ kind: 'shared', key: 'info', address: 'info@a.com' })).toBe('info@a.com');
  });
});

describe('unifiedColumnAccounts', () => {
  const accts = [
    { key: 'dom_a', provider_type: 'inbox2', email_address: 'a.com' },
    { key: 'gmail1', provider_type: 'gmail', email_address: 'me@gmail.com' },
  ];
  const layout = { folders: { dom_a: 'info' }, extras: [{ domainKey: 'dom_a', folder: 'support' }] };

  it('grid mode: MX columns read Inbox, no extras', () => {
    const out = unifiedColumnAccounts(accts, layout, false);
    expect(out.map(a => [a.key, a.folder])).toEqual([['dom_a', 'inbox'], ['gmail1', undefined]]);
  });

  it('list mode: the picked folder, then extra columns after their domain', () => {
    const out = unifiedColumnAccounts(accts, layout, true);
    expect(out.map(a => [a.key, a.folder])).toEqual([['dom_a', 'info'], ['dom_a~support', 'support'], ['gmail1', undefined]]);
    expect(out[1].email_address).toBe('support@a.com');
  });
});
