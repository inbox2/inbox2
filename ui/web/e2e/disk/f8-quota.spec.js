import { test, expect, api, diskUrl, newMenu, node, row, sample, scratch, uniq, uploads } from './support.js'

/* F8. Quota and plan: the paywall, the meter, the warnings, refusal at the
 * quota, and the read-only month after a downgrade. Seeded orgs:
 *   e2e-nodisk    on a plan without Disk
 *   e2e-full      pool 1 GB, all of it used
 *   e2e-warn      pool 1 GB, 85 percent used
 *   e2e-readonly  downgraded two days ago */

test.describe('F8 quota and plan', () => {
  test('F8.1 an org that never had Disk gets the paywall, and every endpoint answers 403', async ({ as }) => {
    const fran = await as('e2e_free')
    await fran.goto(diskUrl('', 'e2e-nodisk'))
    await expect(fran.getByRole('heading', { name: "Disk isn't in your plan" })).toBeVisible()
    await expect(fran.getByRole('link', { name: 'See plans' })).toBeVisible() // the owner may upgrade
    const free = api('e2e_free')
    for (const [m, p, b] of [['GET', '/'], ['GET', '/shares'], ['GET', '/views/recent'], ['GET', '/search?q=a'], ['POST', '/nodes', { name: 'x', kind: 'folder' }], ['POST', '/uploads', { name: 'x', size_bytes: 1 }]]) {
      expect((await free.call(m, p, b)).status, `${m} ${p}`).toBe(403)
    }
  })

  test('F8.2 the meter shows used against allowed and moves by what is uploaded', async ({ page }) => {
    const before = (await api('e2e_owner').get('/')).c_quota
    await page.goto(diskUrl('c'))
    const side = page.getByRole('navigation', { name: 'Disk' })
    // C:\ is the person's own pool, shown as a quiet meter (c3870766): 30 GB on max.
    await expect(side).toContainText(new RegExp(`C:\\\\\\s*[\\d.]+ \\w+ of ${(before.pool_bytes / 1024 ** 3).toFixed(1)} GB`))
    expect(before.pool_bytes % (30 * 1024 ** 3)).toBe(0)
    const f = await scratch('e2e_owner', node('owner_c').id, 'f8-meter')
    const MB100 = 100 * 1024 * 1024
    const n = await api('e2e_owner').upload(f.id, 'hundred-mb.bin', Buffer.alloc(MB100, 1))
    const after = (await api('e2e_owner').get('/')).c_quota
    expect(after.used_bytes - before.used_bytes).toBe(MB100)
    expect(after.pool_bytes).toBe(before.pool_bytes)
    // An older version counts, and so does the trash.
    await api('e2e_owner').upload(f.id, 'hundred-mb.bin', Buffer.alloc(1024, 2), { node_id: n.id, parent_id: undefined })
    const versioned = (await api('e2e_owner').get('/')).c_quota
    expect(versioned.used_bytes - before.used_bytes).toBe(MB100 + 1024)
    await api('e2e_owner').del(`/nodes/${n.id}`)
    const trashed = (await api('e2e_owner').get('/')).c_quota
    expect(trashed.used_bytes).toBe(versioned.used_bytes)
    expect(trashed.trash_bytes).toBeGreaterThanOrEqual(MB100 + 1024)
    await page.reload()
    await expect(side.getByRole('meter').or(side.locator('[class*="meter" i]')).first()).toBeVisible()
  })

  test('F8.3 an upload over the quota is refused up front with the quota message, and nothing is stored', async ({ as }) => {
    // A share: C:\ is the person's own pool, so a full team disk stops uploads to its shares.
    const felix = await as('e2e_full')
    const fullApi = api('e2e_full')
    const { share: s } = await fullApi.post('/shares', { name: uniq('Over'), openness: 'assigned', org_role: 'view' })
    await felix.goto(diskUrl(`d/${s.slug}`, 'e2e-full'))
    await expect(felix.getByRole('status').filter({ hasText: 'Disk is full' })).toBeVisible()
    const chooser = felix.waitForEvent('filechooser')
    await felix.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(sample('notes.md'))
    await expect(uploads(felix).getByRole('alert')).toContainText(/quota|space|full/i)
    await expect(uploads(felix)).toContainText('Failed')
    expect((await fullApi.get('/')).quota.reserved_bytes).toBe(0)
    expect((await fullApi.get(`/nodes/${s.root_node_id}/children`)).nodes).toEqual([])
    const r = await fullApi.call('POST', '/uploads', { parent_id: s.root_node_id, name: 'x.bin', size_bytes: 10 })
    expect(r.status).toBe(422)
    expect(r.data.code ?? r.data.errors?.[0]?.code).toBe('disk_quota_exceeded')
  })

  test('F8.4 warnings show at 80 and 100 percent', async ({ as }) => {
    const wanda = await as('e2e_warn')
    await wanda.goto(diskUrl('c', 'e2e-warn'))
    await expect(wanda.getByRole('status').filter({ hasText: 'Disk is 85% full.' })).toBeVisible()
    const felix = await as('e2e_full')
    await felix.goto(diskUrl('c', 'e2e-full'))
    await expect(felix.getByRole('status').filter({ hasText: /Disk is full\. To upload again/ })).toBeVisible()
  })

  test('F8.5 after a downgrade Disk is read-only: read, download and delete work; writes are refused with a read-only message', async ({ as }) => {
    const rory = await as('e2e_ro')
    await rory.goto(diskUrl('c', 'e2e-readonly'))
    await expect(rory.getByRole('status').filter({ hasText: /Your plan no longer includes Disk\. You can view, download and delete files until/ })).toBeVisible()
    await expect(row(rory, 'kept.md')).toBeVisible()
    await expect(rory.locator('main').getByRole('button', { name: 'Upload', exact: true })).toBeDisabled()
    await expect(newMenu(rory)).toHaveCount(0)
    await row(rory, 'kept.md').getByRole('button', { name: 'kept.md' }).click()
    const d = rory.waitForEvent('download')
    await rory.getByRole('dialog').getByRole('button', { name: 'Download' }).first().click()
    expect((await d).suggestedFilename()).toBe('kept.md')
    await rory.keyboard.press('Escape')
    const ro = api('e2e_ro')
    const c = (await ro.get('/')).c_drive.id
    const refused = await ro.call('POST', '/nodes', { parent_id: c, name: 'nope', kind: 'folder' })
    expect(refused.status).toBe(403)
    expect(JSON.stringify(refused.data)).toContain('disk_read_only')
    expect((await ro.call('GET', `/nodes/${node('ro_file').id}/download`)).status).toBe(200)
    // Delete still works.
    await row(rory, 'kept.md').click({ button: 'right' })
    await rory.getByRole('menuitem', { name: 'Delete' }).click()
    await expect(row(rory, 'kept.md')).toHaveCount(0)
  })
})
