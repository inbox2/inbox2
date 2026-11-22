import { describe, it, expect } from 'vitest'
import { folderRows, readRulesFor, withSendAs, workDomains } from '../folderGrants'

const domains = [{ id: 'dom_a', name: 'a.com' }, { id: 'dom_b', name: 'b.com' }, { id: 'dom_c', name: 'c.com' }]
const sharedByDomain = {
  dom_a: [{ address: 'info@a.com', display_name: 'A' }],
  dom_b: [{ address: 'support@b.com' }],
  dom_c: [{ address: 'sales@c.com' }],
}
const rule = (id, value, memberId = 'mem_1', operator = 'equals') => ({
  id, conditions: [{ field: 'to', operator, value }], actions: [{ type: 'grant_access', value: memberId }],
})
const scoped = {
  id: 'mem_1', role: 'member', all_domains: false,
  domains: [{ id: 'dom_a', name: 'a.com' }],
  mailboxes: [{ email_address: 'ali@b.com' }],
  send_as_addresses: ['support@b.com', 'old@b.com'],
}

describe('folder grants', () => {
  it('finds only exact `to equals` grant rules for the member', () => {
    const rules = [rule('r1', 'Support@b.com'), rule('r2', 'support@b.com', 'mem_2'), rule('r3', 'support@b.com', 'mem_1', 'contains')]
    expect(readRulesFor(rules, 'mem_1', 'support@b.com').map((r) => r.id)).toEqual(['r1'])
  })

  it('toggles send-as without duplicates', () => {
    expect(withSendAs(['info@a.com'], 'INFO@a.com', true)).toEqual(['info@a.com'])
    expect(withSendAs(['info@a.com', 'x@a.com'], 'info@a.com', false)).toEqual(['x@a.com'])
  })

  it('works on pool, mailbox and send-as domains only', () => {
    expect(workDomains(scoped, domains).map((d) => d.id)).toEqual(['dom_a', 'dom_b'])
    expect(workDomains({ ...scoped, all_domains: true }, domains)).toHaveLength(3)
  })

  it('builds own, shared and leftover rows for a scoped member', () => {
    const rows = folderRows({ member: scoped, domains, sharedByDomain, rules: [rule('r1', 'support@b.com')] })
    expect(rows.map((r) => [r.kind, r.address])).toEqual([
      ['own', 'ali@b.com'], ['shared', 'info@a.com'], ['shared', 'support@b.com'], ['extra', 'old@b.com'],
    ])
    expect(rows[1]).toMatchObject({ read: true, readLocked: 'domain', replyAs: false })
    expect(rows[2]).toMatchObject({ read: true, readLocked: null, replyAs: true })
    expect(rows[2].rules.map((r) => r.id)).toEqual(['r1'])
  })

  it('locks Read for admins', () => {
    const rows = folderRows({ member: { ...scoped, role: 'admin', send_as_addresses: [] }, domains, sharedByDomain, rules: [] })
    expect(rows.filter((r) => r.kind === 'shared').every((r) => r.read && r.readLocked === 'admin')).toBe(true)
  })
})
