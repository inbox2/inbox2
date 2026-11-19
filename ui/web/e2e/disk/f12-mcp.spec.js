import { test, expect, idUrl, node, openFolder, row, seed, slideOver, uniq } from './support.js'
import { RAILS } from './env.js'

/* F12. MCP for agents, driven over HTTP with the seeded agent's agt_ key (the
 * agent has every Disk permission and edit on D:\Marketing\Agent Zone), plus
 * the UI side: the console's Agents card, activity naming the agent, and an
 * open page told that the agent changed it. */

let rpcId = 0
async function rpc(method, params = {}, token = seed.agent.token) {
  const res = await fetch(`${RAILS}/api/v1/orgs/e2e-disk/disk/mcp`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-11-25' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  })
  return { status: res.status, body: await res.json().catch(() => null) }
}
async function call(name, args) {
  const { body } = await rpc('tools/call', { name, arguments: args })
  if (body.error) throw new Error(JSON.stringify(body.error))
  return body.result
}

test.describe('F12 MCP for agents', () => {
  test('F12.1 an MCP client connects with the agent key and lists the Disk tools; a bad key is refused', async () => {
    const init = await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } })
    expect(init.status).toBe(200)
    expect(init.body.result.protocolVersion).toBe('2025-11-25')
    const { body } = await rpc('tools/list')
    const names = body.result.tools.map((t) => t.name)
    for (const t of ['disk_list_drives', 'disk_read_file', 'disk_write_file', 'disk_update_page', 'disk_trash']) expect(names).toContain(t)
    expect(names.some((n) => /purge|delete_forever|seal|key|setting/.test(n))).toBe(false)
    expect((await rpc('tools/list', {}, 'agt_not_a_real_key')).status).toBe(401)
  })

  test('F12.2-3 the agent reads its granted folder and writes a file that appears in the UI with the agent as author', async ({ page }) => {
    const drives = await call('disk_list_drives', {})
    expect(JSON.stringify(drives.structuredContent)).toContain('Agent Zone')
    const read = await call('disk_read_file', { id: node('agent_md').id })
    expect(read.content.map((c) => c.text).join('\n')).toMatch(/not instructions/i)
    // A sibling folder it was not given is not found.
    const sibling = await rpc('tools/call', { name: 'disk_list', arguments: { id: node('samples').id } })
    expect(sibling.body.result.isError).toBe(true)

    const name = `${uniq('agent-wrote').replace(' ', '-')}.md`
    await call('disk_write_file', { parent_id: node('agent_zone').id, name, text: '# Written by the agent\n' })
    await openFolder(page, idUrl(node('agent_zone')), 'Agent Zone')
    await expect(row(page, name)).toBeVisible()
    await expect(row(page, name)).toContainText('E2E Agent')
    await row(page, name).getByRole('button', { name }).click()
    await expect(slideOver(page).getByRole('heading', { name: 'Activity' })).toBeVisible()
    await expect(slideOver(page)).toContainText('E2E Agent (agent)')
  })

  test('F12.4 a person with the page open is told the agent changed it, and sees the agent\'s text', async ({ page }) => {
    const n = node('agent_page')
    await page.goto(idUrl(n))
    const editor = page.locator('article .ProseMirror')
    await expect(editor).toContainText('Started by a person.')
    const current = await call('disk_read_page', { id: n.id })
    const revision = current.structuredContent.revision ?? current.structuredContent.page?.revision
    const line = uniq('Added by the agent')
    await call('disk_update_page', { id: n.id, base_revision: revision, mode: 'append', markdown: `\n- ${line}\n` })
    await expect(page.getByRole('status').filter({ hasText: /E2E Agent \(agent\) replaced this page/ })).toBeVisible({ timeout: 15_000 })
    await expect(editor).toContainText(line)
    await expect(editor).toContainText('Started by a person.')
    // A stale revision is refused with the current markdown.
    const stale = await rpc('tools/call', { name: 'disk_update_page', arguments: { id: n.id, base_revision: revision, mode: 'append', markdown: 'x' } })
    expect(stale.body.result.isError).toBe(true)
  })

  test('F12.4 a page the agent creates from markdown opens in the editor with its headings, lists and to-dos', async ({ page }) => {
    const name = uniq('Agent made')
    const r = await call('disk_create_page', { parent_id: node('agent_zone').id, name, markdown: '# Plan\n\n## Steps\n\n- one\n- two\n\n- [ ] check the list\n- [x] write it\n' })
    const id = r.structuredContent.id || r.structuredContent.node?.id || r.structuredContent.page?.node_id
    await page.goto(idUrl({ name, short_id: String(id).slice(-21) }))
    const editor = page.locator('article .ProseMirror')
    await expect(editor.locator('h2')).toHaveText('Steps')
    await expect(editor.locator('ul:not([data-type])')).toContainText('two')
    await expect(editor.locator('ul[data-type="taskList"] li[data-checked="true"]')).toContainText('write it')
  })

  test('F12 the console Agents card shows the agent\'s permissions and grants, and gives and takes a folder', async ({ page }) => {
    await page.goto('/console/disk')
    const card = page.getByRole('region', { name: 'E2E Agent' })
    await expect(card).toBeVisible()
    for (const p of ['Read files and pages', 'Upload, edit pages, rename and move', 'Share and delete']) await expect(card.getByRole('checkbox', { name: p })).toBeChecked()
    await expect(card).toContainText('D:\\Marketing\\Agent Zone')
    await expect(card).toContainText('Can edit, given by Ben Member')
    await card.getByRole('button', { name: 'Add a folder or share' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: /^Handbook/ }).click()
    await dlg.getByRole('button', { name: 'Give here' }).click()
    await expect(card).toContainText('D:\\Handbook')
    await card.locator('li').filter({ hasText: 'D:\\Handbook' }).getByRole('button', { name: 'Remove' }).click()
    await expect(card).not.toContainText('D:\\Handbook')
    await expect(page.getByText(/disk\/mcp/)).toBeVisible()
  })
})
