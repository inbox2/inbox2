import { test, expect, api, diskUrl, idUrl, node, openFolder, row, share, tile, uniq, user } from './support.js'

/* F3. Shares on D:\. */

test.describe('F3 shares', () => {
  test('F3.1 owners and admins create a share with a name, colour and emblem, open or assigned; a member cannot', async ({ page, as }) => {
    const name = uniq('Ops')
    await page.goto(diskUrl('d'))
    await page.locator('main').getByRole('button', { name: 'New share' }).first().click()
    const dlg = page.getByRole('dialog')
    await dlg.getByLabel('Name').fill(name)
    await dlg.getByRole('group', { name: 'Icon' }).getByRole('button', { name: 'Change' }).click()
    await dlg.getByRole('radio', { name: 'engineering' }).click({ force: true })
    await dlg.getByRole('group', { name: 'Colour' }).getByRole('button', { name: 'Change' }).click()
    await dlg.getByRole('radio', { name: 'green' }).click({ force: true })
    await dlg.getByText('Everyone in the organization').click()
    await dlg.getByRole('button', { name: 'Create share' }).click()
    // Creating goes straight on to its members.
    await expect(page.getByRole('heading', { name: `Members of ${name}` })).toBeVisible()
    await page.getByRole('dialog').getByRole('button', { name: 'Done' }).click()
    await expect(tile(page, name)).toContainText('open to everyone')

    // Every member sees an open share; a plain member has no New share.
    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('d'))
    await expect(tile(ana, name)).toBeVisible()
    await expect(ana.getByRole('button', { name: /New share/ })).toHaveCount(0)
    const r = await api('e2e_ana').call('POST', '/shares', { name: uniq('nope'), openness: 'assigned', org_role: 'view' })
    expect(r.status).toBe(403)
  })

  test('F3.2 first run offers the share templates; ticking three creates exactly those three', async ({ as }) => {
    // Nearly Full is an org with no shares yet: its owner gets the first-run templates.
    const wanda = await as('e2e_warn')
    await wanda.goto(diskUrl('d', 'e2e-warn'))
    await expect(wanda.getByRole('heading', { name: 'No shares yet. Set up the first ones.' })).toBeVisible()
    for (const t of ['Marketing', 'Finance', 'Design']) await wanda.getByRole('button', { name: t, exact: true }).click()
    await wanda.getByRole('button', { name: 'Create 3 shares' }).click()
    for (const t of ['Marketing', 'Finance', 'Design']) await expect(tile(wanda, t)).toBeVisible()
    await expect(wanda.getByRole('listbox', { name: 'Shares' }).getByRole('option')).toHaveCount(3)
    const { shares } = await api('e2e_warn').get('/shares')
    expect(shares.map((s) => s.icon).sort()).toEqual(['design', 'finance', 'marketing'])
  })

  test('F3.3 roles: a viewer previews and downloads but cannot upload, rename or delete; a manager adds and removes members', async ({ as }) => {
    const vic = await as('e2e_vic')
    await openFolder(vic, idUrl(node('samples')), 'Samples')
    await row(vic, 'notes.md').getByRole('button', { name: 'notes.md' }).click()
    await expect(vic.getByRole('dialog').getByRole('button', { name: 'Download' }).first()).toBeVisible()
    await vic.keyboard.press('Escape')
    const v = api('e2e_vic')
    expect((await v.call('GET', `/nodes/${node('sample_notes_md').id}/download`)).status).toBe(200)
    expect((await v.call('PATCH', `/nodes/${node('sample_notes_md').id}`, { name: 'x.md' })).status).toBe(403)
    expect((await v.call('DELETE', `/nodes/${node('sample_notes_md').id}`)).status).toBe(403)
    expect((await v.call('POST', '/uploads', { parent_id: node('samples').id, name: 'x.md', size_bytes: 3 })).status).toBe(403)

    // Ben manages Marketing: adds Nina, then removes her.
    const ben = await as('e2e_ben')
    await ben.goto(diskUrl('d'))
    await tile(ben, 'Marketing').click({ button: 'right' })
    await ben.getByRole('menuitem', { name: 'Members' }).click()
    const dlg = ben.getByRole('dialog')
    await expect(dlg).toContainText('Vic Viewer')
    await dlg.getByRole('combobox', { name: 'Person' }).selectOption({ label: 'Nina New' })
    await dlg.getByRole('combobox', { name: 'Role', exact: true }).selectOption('view')
    await dlg.getByRole('button', { name: 'Add' }).click()
    const nina = dlg.locator('li').filter({ hasText: 'Nina New' })
    await expect(nina).toBeVisible()
    await nina.getByRole('button', { name: 'Remove' }).click()
    await expect(nina).toHaveCount(0)
    // Ana edits but does not manage: the API refuses her member changes.
    const r = await api('e2e_ana').call('PUT', `/shares/${share('Marketing').id}/members/${user('e2e_new').membership_id}`, { role: 'view' })
    expect(r.status).toBe(403)
  })

  test('F3.4 rename, change the emblem, archive, and delete a share with its name typed back into an admin-only trash', async ({ page, as }) => {
    const name = uniq('Temp')
    const { share: s } = await api('e2e_owner').post('/shares', { name, openness: 'org', org_role: 'view', icon: 'sales' })
    await api('e2e_owner').upload(s.root_node_id, 'inside.md', '# inside\n')
    await page.goto(diskUrl('d'))
    await tile(page, name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Edit share' }).click()
    const renamed = `${name} renamed`
    await page.getByRole('dialog').getByLabel('Name').fill(renamed)
    await page.getByRole('dialog').getByRole('group', { name: 'Icon' }).getByRole('button', { name: 'Change' }).click()
    await page.getByRole('dialog').getByRole('radio', { name: 'legal' }).click({ force: true })
    await page.getByRole('dialog').getByRole('button', { name: 'Save' }).click()
    await expect(tile(page, renamed)).toBeVisible()

    await tile(page, renamed).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Archive (read-only)' }).click()
    await expect(tile(page, renamed)).toContainText('archived')

    await tile(page, renamed).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Delete share' }).click()
    const confirm = page.getByRole('dialog')
    await expect(confirm.getByRole('button', { name: 'Delete share' })).toBeDisabled()
    await confirm.getByRole('textbox').fill(renamed)
    await confirm.getByRole('button', { name: 'Delete share' }).click()
    await expect(tile(page, renamed)).toHaveCount(0)

    // In the admin trash for 30 days; members no longer see it.
    await page.getByRole('button', { name: /Deleted shares/ }).click()
    const trashed = page.locator('li').filter({ hasText: renamed })
    await expect(trashed).toContainText('kept until')
    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('d'))
    await expect(tile(ana, renamed)).toHaveCount(0)
    await expect(ana.getByRole('button', { name: /Deleted shares/ })).toHaveCount(0)
    await trashed.getByRole('button', { name: 'Restore' }).click()
    await expect(tile(page, renamed)).toBeVisible()
  })
})
