import { test, expect, api, folderUrl, node, openFolder, row, scratch, seed, slideOver } from './support.js'

/* F9. Mail integration, as far as local data allows: the seed puts one MX mail
 * ("Quarterly figures", with figures.csv) in e2e-disk.test. */

test.describe('F9 mail integration', () => {
  test('F9.1 save a mail attachment to a Disk folder; it shows the sender and subject', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f9-saved')
    await page.goto('/e2e-disk/mail')
    await page.getByText('Quarterly figures').first().click()
    const chip = page.getByRole('button', { name: /figures\.csv/ }).first()
    await expect(chip).toBeVisible()
    // Esc closes the picker even inside the mail client, whose own keys come first otherwise.
    await chip.click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Save to Disk…' }).click()
    await page.getByRole('dialog').getByRole('button', { name: /^C:\\/ }).click()
    await page.keyboard.press('Escape')
    await expect(page.getByRole('dialog')).toHaveCount(0)
    await chip.click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Save to Disk…' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: /^C:\\/ }).click()
    await dlg.getByRole('button', { name: new RegExp(`^${f.name}`) }).click()
    await dlg.getByRole('button', { name: 'Save here' }).click()
    await expect(page.getByRole('status').filter({ hasText: 'Saved figures.csv to Disk.' })).toBeVisible()

    await openFolder(page, folderUrl(f), f.name)
    await row(page, 'figures.csv').getByRole('button', { name: 'figures.csv' }).click()
    const panel = slideOver(page)
    await expect(panel).toContainText('From mail')
    await expect(panel).toContainText('carol@client.test')
    await expect(panel).toContainText('Quarterly figures')
  })

  test('F9.2 the composer attaches a Disk file as a copy, or inserts a Disk link', async ({ page }) => {
    await page.goto('/e2e-disk/mail')
    await page.getByRole('button', { name: /Compose/ }).first().click()
    await page.getByRole('button', { name: 'From Disk' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: /^Marketing/ }).click()
    await dlg.getByRole('button', { name: /^Samples/ }).click()
    await dlg.getByRole('button', { name: /^notes\.md/ }).click()
    await expect(page.getByText('notes.md').last()).toBeVisible()

    await page.getByRole('button', { name: 'Disk link' }).click()
    const dlg2 = page.getByRole('dialog')
    await dlg2.getByRole('button', { name: /^Marketing/ }).click()
    await dlg2.getByRole('button', { name: /^Samples/ }).click()
    await dlg2.getByRole('button', { name: /^data\.csv/ }).click()
    const link = page.locator('.ProseMirror a', { hasText: 'data.csv' })
    await expect(link).toBeVisible()
    const href = await link.getAttribute('href')
    expect(href).toMatch(/\/share\/data-csv\/[A-Za-z0-9]{22}$/)
    // The recipient opens it.
    const res = await fetch(`${new URL(href).origin.replace('4621', '4620')}/api/v1/disk/links/${href.split('/').at(-1)}`)
    expect(res.status).toBe(200)
  })

  test('F9.3 a Disk file over the mail size limit offers to send a link instead', async ({ page }) => {
    test.setTimeout(120_000)
    const limit = (await api('e2e_owner').get('/')).settings.mail_attachment_limit_bytes
    const f = await scratch('e2e_owner', node('owner_c').id, 'f9-big')
    await api('e2e_owner').upload(f.id, 'too-big.bin', Buffer.alloc(limit + 1024, 3))
    await page.goto('/e2e-disk/mail')
    await page.getByRole('button', { name: /Compose/ }).first().click()
    await page.getByRole('button', { name: 'From Disk' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: /^C:\\/ }).click()
    await dlg.getByRole('button', { name: new RegExp(`^${f.name}`) }).click()
    await dlg.getByRole('button', { name: /^too-big\.bin/ }).click()
    await expect(page.getByText('Too large to send')).toBeVisible()
    await page.getByRole('button', { name: 'Insert link' }).click()
    await expect(page.locator('.ProseMirror a', { hasText: 'too-big.bin' })).toBeVisible()
    void seed
  })
})
