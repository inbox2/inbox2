import fs from 'node:fs'
import { test, expect, api, diskUrl, folderUrl, idUrl, node, openFolder, row, sample, scratch, seed, share, slideOver, uniq, user } from './support.js'
import { RAILS } from './env.js'

/* F4. Sharing with people, the Access column, public links and the public viewer. */

const owner = () => api('e2e_owner')
const linkPath = (key) => seed.links[key].path

test.describe('F4 sharing with people', () => {
  test('F4.1 share a folder with a named member; they get it in Shared with me and reach nothing above it', async ({ page, as }) => {
    const parent = await scratch('e2e_owner', node('owner_c').id, 'f4-above')
    const f = await owner().folder(parent.id, uniq('For Ben'))
    const sub = await owner().folder(f.id, 'Inside')
    await openFolder(page, folderUrl(parent), parent.name)
    await row(page, f.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Share...' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('combobox', { name: 'Person' }).selectOption({ label: 'Ben Member' })
    await dlg.getByRole('combobox', { name: 'Role', exact: true }).selectOption('edit')
    await dlg.getByRole('button', { name: 'Add' }).click()
    await expect(dlg.locator('li').filter({ hasText: 'Ben Member' })).toBeVisible()
    await dlg.getByRole('button', { name: 'Done' }).click()

    const ben = await as('e2e_ben')
    await ben.goto(diskUrl('shared-with-me'))
    await expect(row(ben, f.name)).toBeVisible()
    // The subfolder needs no grant of its own; the folder above is not found.
    await ben.goto(folderUrl(sub))
    await expect(ben.getByRole('heading', { level: 1, name: 'Inside' })).toBeVisible()
    await ben.goto(folderUrl(parent))
    await expect(ben.getByRole('alert')).toContainText('Not found')
    expect((await api('e2e_ben').call('GET', `/nodes/${parent.id}`)).status).toBe(404)
  })

  test('F4.2 the Access column shows avatars for own grants and a dashed "inherits"; hover says who and from where', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    const cell = row(page, 'notes.md').locator('[data-access]')
    await expect(cell).toContainText('same as folder')
    await cell.hover()
    const tip = cell.getByRole('tooltip')
    await expect(tip).toBeVisible()
    await expect(tip).toContainText('Same as D:\\Marketing\\Samples')
    await expect(tip).toContainText('Ana Member')
    await expect(tip).toContainText('Vic Viewer')

    // Avatars where the item has its own grant (For Ana on C:\).
    await page.goto(diskUrl('c'))
    const own = row(page, 'For Ana').locator('[data-access]')
    await expect(own.getByLabel('Shared with 1 person')).toBeVisible()
    await own.focus()
    await expect(own.getByRole('tooltip')).toContainText('Ana Member')
  })

  test('F4.3 the share dialog lists access and its source; removing the only source takes the item from Shared with me', async ({ page, as }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f4-revoke')
    await owner().put(`/nodes/${f.id}/grants/${user('e2e_vic').membership_id}`, { role: 'view' })
    const vic = await as('e2e_vic')
    await vic.goto(diskUrl('shared-with-me'))
    await expect(row(vic, f.name)).toBeVisible()

    await page.goto(diskUrl('c'))
    await row(page, f.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Share...' }).click()
    const line = page.getByRole('dialog').locator('li').filter({ hasText: 'Vic Viewer' })
    await expect(line.getByRole('combobox', { name: 'Role for Vic Viewer' })).toHaveValue('view')
    await line.getByRole('button', { name: 'Remove' }).click()
    await expect(line).toHaveCount(0)
    await vic.reload()
    await expect(row(vic, f.name)).toHaveCount(0)

    // A grant on something in a share the person is also a member of: removal is disabled and says why.
    const inShare = await api('e2e_ben').folder(node('samples').id, uniq('f4-both'))
    await api('e2e_ben').put(`/nodes/${inShare.id}/grants/${user('e2e_ana').membership_id}`, { role: 'edit' })
    const ben = await as('e2e_ben')
    await openFolder(ben, idUrl(node('samples')), 'Samples')
    await row(ben, inShare.name).click({ button: 'right' })
    await ben.getByRole('menuitem', { name: 'Share...' }).click()
    const dlg = ben.getByRole('dialog')
    await expect(dlg).toContainText('Through the share Marketing')
    const anaLine = dlg.locator('li').filter({ hasText: 'Ana Member' }).first()
    await expect(anaLine.getByRole('button', { name: 'Remove' })).toBeDisabled()
    await expect(anaLine.getByRole('button', { name: 'Remove' })).toHaveAttribute('title', /Also a member of Marketing/)
  })

  test('F4.7 a person is told when something is shared with them, and the link opens it', async ({ as }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f4-notify')
    await owner().put(`/nodes/${f.id}/grants/${user('e2e_new').membership_id}`, { role: 'view' })
    const { notifications } = await api('e2e_new').get('/notifications')
    const n = notifications.find((x) => x.kind === 'disk_shared' && x.title.includes(f.name))
    expect(n).toBeTruthy()
    const nina = await as('e2e_new')
    await nina.goto(new URL(n.url, 'http://x').pathname)
    await expect(nina.getByRole('heading', { level: 1, name: f.name })).toBeVisible()
  })
})

test.describe('F4 public links', () => {
  test('F4.4 the link dialog makes links with password, expiry and hidden download, and says what hiding does', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f4-links')
    await owner().upload(f.id, 'shared.pdf', fs.readFileSync(sample('report.pdf')))
    await openFolder(page, folderUrl(f), f.name)
    await row(page, 'shared.pdf').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Public link...' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByText('Password, expiry, download').click() // folded away
    await dlg.getByLabel('Password (optional)').fill('pa55word')
    await dlg.getByText('Hide the Download button').click()
    await dlg.getByRole('button', { name: 'Create link' }).click()
    const url = await dlg.getByRole('textbox', { name: 'New link' }).inputValue()
    expect(url).toMatch(/\/share\/shared-pdf\/[A-Za-z0-9]{22}$/)
    await expect(dlg.locator('li').first()).toContainText('password, no download button')
    // Revoke it: the link stops at once.
    await dlg.locator('li').first().getByRole('button', { name: 'Revoke' }).click()
    await expect(dlg).toContainText('No links yet')
    const token = url.split('/').at(-1)
    expect((await fetch(`${RAILS}/api/v1/disk/links/${token}`)).status).toBe(404)
  })

  test('F4.5 a public link opens without an account and previews a PDF, with the abuse address @smoke', async ({ browser }) => {
    const ctx = await browser.newContext() // a private window: no session
    const page = await ctx.newPage()
    await page.goto(linkPath('open'))
    await expect(page.getByRole('heading', { name: 'report.pdf' })).toBeVisible()
    await expect(page.locator('canvas').first()).toBeVisible({ timeout: 30_000 })
    await expect(page.getByRole('button', { name: /^Download, / })).toBeVisible()
    await expect(page.getByRole('contentinfo')).toContainText('Report abuse to')
    const d = page.waitForEvent('download')
    await page.getByRole('button', { name: /^Download, / }).click()
    expect((await d).suggestedFilename()).toBe('report.pdf')
    await ctx.close()
  })

  test('F4.4 a password link is locked until the right password; a wrong one is refused', async ({ browser }) => {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await page.goto(linkPath('password'))
    await expect(page.getByRole('heading', { name: 'This link has a password' })).toBeVisible()
    await page.getByLabel('Password').fill('wrong')
    await page.getByRole('button', { name: 'Open' }).click()
    await expect(page.getByRole('alert')).toContainText("That password isn't right")
    await page.getByLabel('Password').fill('open-sesame')
    await page.getByRole('button', { name: 'Open' }).click()
    await expect(page.getByRole('heading', { name: 'report.pdf' })).toBeVisible()
    await ctx.close()
  })

  test('F4.4 hidden download: the page previews and shows no Download', async ({ browser }) => {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await page.goto(linkPath('hidden'))
    await expect(page.getByRole('heading', { name: 'report.pdf' })).toBeVisible()
    await expect(page.locator('canvas').first()).toBeVisible({ timeout: 30_000 })
    await expect(page.getByRole('button', { name: /Download/ })).toHaveCount(0)
    const r = await (await fetch(`${RAILS}/api/v1/disk/links/${seed.links.hidden.token}/download`)).json()
    expect(r.download.url).toBeNull()
    expect(r.download.preview_url).toBeTruthy()
    await ctx.close()
  })

  test('F4.4 expired and revoked links show the link-does-not-work page', async ({ browser }) => {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    for (const key of ['expired', 'revoked']) {
      await page.goto(linkPath(key))
      await expect(page.getByRole('alert')).toContainText("This link doesn't work")
      await expect(page.getByRole('alert')).toContainText('expired')
    }
    await page.goto('/share/nothing/AAAAAAAAAAAAAAAAAAAAAA')
    await expect(page.getByRole('alert')).toContainText("This link doesn't work")
    await ctx.close()
  })

  test('F4.4 a folder link browses its own subtree and previews inside it', async ({ browser }) => {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await page.goto(linkPath('folder'))
    const nav = page.getByRole('navigation', { name: 'Folder' })
    await expect(nav).toContainText('Launch 2026')
    await page.getByRole('button', { name: /Assets/ }).click()
    await page.getByRole('button', { name: /Hero/ }).click()
    await expect(nav).toContainText('Hero')
    await page.getByRole('button', { name: /hero-banner\.png/ }).click()
    await expect(page.getByRole('dialog').locator('img').first()).toBeVisible()
    await page.keyboard.press('Escape')
    await nav.getByRole('button', { name: 'Launch 2026' }).click()
    await expect(page.getByRole('button', { name: /brief\.md/ })).toBeVisible()
    // Nothing above the linked folder is reachable.
    const above = await fetch(`${RAILS}/api/v1/disk/links/${seed.links.folder.token}?node_id=${share('Marketing').root_id}`)
    expect(above.status).toBe(404)
    await ctx.close()
  })

  test('F4.4 wrong passwords are rate limited', async () => {
    const { link } = await api('e2e_ben').post(`/nodes/${node('sample_data_csv').id}/links`, { password: 'right-one' })
    // A made-up client address, so this test's throttle bucket is its own.
    const tries = []
    for (let i = 0; i < 12; i++) {
      tries.push((await fetch(`${RAILS}/api/v1/disk/links/${link.token}/unlock`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': '10.20.30.40' }, body: JSON.stringify({ password: 'nope' }),
      })).status)
    }
    expect(tries.slice(0, 10).every((s) => s === 403)).toBe(true)
    expect(tries.at(-1)).toBe(429)
  })

  test('F4.6 org admins turn public links off: the option goes and existing links stop resolving', async ({ page }) => {
    try {
      await owner().put('/admin/settings', { links_enabled: false })
      expect((await fetch(`${RAILS}/api/v1/disk/links/${seed.links.open.token}`)).status).toBe(404)
      await openFolder(page, idUrl(node('samples')), 'Samples')
      await row(page, 'notes.md').click({ button: 'right' })
      await expect(page.getByRole('menu')).toBeVisible()
      await expect(page.getByRole('menuitem', { name: 'Public link...' })).toHaveCount(0)
      expect((await api('e2e_ben').call('POST', `/nodes/${node('sample_notes_md').id}/links`, {})).status).toBe(403)
    } finally {
      await owner().put('/admin/settings', { links_enabled: true })
    }
    expect((await fetch(`${RAILS}/api/v1/disk/links/${seed.links.open.token}`)).status).toBe(200)
  })

  test('F4.2 the slide-over shows who has access and where it comes from', async ({ page }) => {
    await page.goto(idUrl(node('sample_notes_md')))
    const panel = slideOver(page)
    await expect(panel.getByRole('heading', { name: 'Your access' })).toBeVisible()
    await expect(panel).toContainText("You're an owner or admin")
  })
})
