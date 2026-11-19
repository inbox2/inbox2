import fs from 'node:fs'
import path from 'node:path'
import { test, expect, api, diskUrl, folderUrl, idUrl, newItem, newSealedShareMenu, node, openFolder, row, sample, scratch, seed, share, slideOver, tile, uploads } from './support.js'
import { HERE, RAILS, STATE } from './env.js'
import { surl, sapi, newSealedShare, uploadHere, addHolder, openShare, unlockIn, waitOpen } from './sealedSupport.js'

/* The screenshot set for review (yarn e2e:disk:screens): every Disk screen and
 * state at desktop 1440x900 and phone 390x844, into e2e/disk/screens/<size>/.
 * Not assertions about pixels; a stable set of frames to look at. */

const OUT = path.join(HERE, 'screens')
const SIZES = [
  { name: 'desktop', viewport: { width: 1440, height: 900 } },
  { name: 'phone', viewport: { width: 390, height: 844 } },
]

for (const size of SIZES) {
  test.describe(`screens ${size.name}`, () => {
    test.use({ viewport: size.viewport })
    const shot = async (page, name) => {
      fs.mkdirSync(path.join(OUT, size.name), { recursive: true })
      // The dev-only React Grab button is not part of the product.
      await page.addStyleTag({ content: '[data-react-grab]{display:none!important}' }).catch(() => {})
      await page.waitForTimeout(350) // fonts and fades settle
      await page.screenshot({ path: path.join(OUT, size.name, `${name}.png`), animations: 'disabled', caret: 'hide' })
    }
    const phone = size.name === 'phone'

    test('browse: C:\\ list, grid, D:\\ tiles, views, search, filters', async ({ page }) => {
      await page.goto(diskUrl('c'))
      await expect(row(page, 'Clients')).toBeVisible()
      await shot(page, '01-c-list')
      await page.getByRole('button', { name: 'Grid view' }).click()
      await shot(page, '02-c-grid')
      await page.getByRole('button', { name: 'List view' }).click()
      await page.goto(diskUrl('d'))
      await expect(tile(page, 'Marketing')).toBeVisible()
      await shot(page, '03-d-tiles')
      await page.goto(idUrl(node('samples')))
      await expect(row(page, 'notes.md')).toBeVisible()
      await shot(page, '04-share-folder')
      await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('re')
      await expect(row(page, 'report.pdf')).toBeVisible()
      await shot(page, '05-search')
      await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('')
      await page.getByRole('button', { name: 'Pages', exact: true }).click()
      await expect(page.getByText('Nothing matches')).toBeVisible()
      await shot(page, '06-filter-no-match')
      await page.goto(diskUrl('shared-with-me'))
      await expect(page.locator('main h1')).toBeVisible()
      await shot(page, '07-shared-with-me')
      await page.goto(diskUrl('trash'))
      await expect(page.locator('main h1')).toBeVisible()
      await shot(page, '08-trash')
      await page.goto(idUrl(node('deep')))
      await expect(row(page, 'invoice-001.pdf')).toBeVisible()
      await shot(page, '09-deep-breadcrumbs')
      if (phone) {
        await page.getByRole('button', { name: 'Drives and views' }).click()
        await shot(page, '10-phone-sidebar-open')
      }
    })

    test('empty states and skeleton', async ({ page, as }) => {
      const nina = await as('e2e_new', { viewport: size.viewport })
      await nina.goto(diskUrl('c'))
      await expect(nina.getByText(/Nothing here yet/)).toBeVisible()
      await shot(nina, '11-empty-drive')
      const f = await scratch('e2e_owner', node('owner_c').id, 'Empty folder')
      await openFolder(page, folderUrl(f), f.name)
      await shot(page, '12-empty-folder')
      await page.route('**/disk/nodes/*/children*', () => {}) // never answers: the skeleton stays
      await page.goto(idUrl(node('samples')))
      await expect(page.locator('[class*="skRow"]').first()).toBeVisible()
      await shot(page, '13-skeleton')
      await page.unroute('**/disk/nodes/*/children*')
    })

    test('selection, menus and dialogs', async ({ page }) => {
      await openFolder(page, idUrl(node('samples')), 'Samples')
      for (const n of ['notes.md', 'data.csv', 'app.js']) await page.getByRole('checkbox', { name: `Select ${n}` }).check()
      await shot(page, '14-bulk-bar')
      await page.keyboard.press('Escape')
      await row(page, 'notes.md').click({ button: 'right' })
      await expect(page.getByRole('menu')).toBeVisible()
      await shot(page, '15-context-menu')
      await page.getByRole('menuitem', { name: 'Move to...' }).click()
      await page.getByRole('dialog').getByRole('button', { name: /^Marketing/ }).click()
      await expect(page.getByRole('dialog').getByRole('button', { name: /^Launch 2026/ })).toBeVisible()
      await shot(page, '16-move-dialog')
      await page.keyboard.press('Escape')
      await row(page, 'notes.md').click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Share...' }).click()
      await expect(page.getByRole('dialog')).toContainText('Through the share Marketing')
      await shot(page, '17-share-dialog')
      await page.getByRole('dialog').getByRole('button', { name: 'Done' }).click()
      await row(page, 'notes.md').click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Public link...' }).click()
      await page.getByRole('dialog').getByRole('button', { name: 'Create link' }).click()
      await expect(page.getByRole('dialog').getByRole('textbox', { name: 'New link' })).toBeVisible()
      await shot(page, '18-link-dialog')
      await page.getByRole('dialog').getByRole('button', { name: 'Done' }).click()
      await page.goto(diskUrl('d'))
      await page.locator('main').getByRole('button', { name: 'New share' }).first().click()
      await shot(page, '19-new-share-dialog')
      await page.keyboard.press('Escape')
      await tile(page, 'Marketing').click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Members' }).click()
      await expect(page.getByRole('dialog')).toContainText('Vic Viewer')
      await shot(page, '20-share-members')
    })

    test('uploads: in progress and a name clash', async ({ page }) => {
      const f = await scratch('e2e_owner', node('owner_c').id, 'Uploads')
      await api('e2e_owner').upload(f.id, 'notes.md', '# there already\n')
      await openFolder(page, folderUrl(f), f.name)
      const big = path.join(STATE, 'big-20mb.bin')
      if (!fs.existsSync(big)) fs.writeFileSync(big, Buffer.alloc(20 * 1024 * 1024, 7))
      await page.route('**/localhost:4900/**', async (route) => {
        if (route.request().method() === 'PUT') await new Promise((r) => setTimeout(r, 60_000))
        await route.continue().catch(() => {})
      })
      const chooser = page.waitForEvent('filechooser')
      await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
      await (await chooser).setFiles([big, sample('notes.md')])
      await expect(uploads(page).getByText('Name taken')).toBeVisible()
      await expect(uploads(page).getByText('Uploading', { exact: true })).toBeVisible()
      await shot(page, '21-upload-progress-and-clash')
      await page.unroute('**/localhost:4900/**')
    })

    const previews = [
      ['22-preview-pdf', 'sample_report_pdf', (p) => p.locator('canvas')],
      ['23-preview-image', 'sample_photo_jpg', (p) => p.getByRole('img', { name: 'photo.jpg' })],
      ['24-preview-svg', 'sample_diagram_svg', (p) => p.getByRole('img', { name: 'diagram.svg' })],
      ['25-preview-video', 'sample_clip_mp4', (p) => p.locator('video')],
      ['26-preview-audio', 'sample_voice_m4a', (p) => p.locator('audio')],
      ['27-preview-markdown', 'sample_notes_md', (p) => p.locator('iframe')],
      ['28-preview-code', 'sample_app_js', (p) => p.locator('.cm-content')],
      ['29-preview-csv', 'sample_data_csv', (p) => p.locator('table')],
      ['30-preview-docx', 'sample_plan_docx', (p) => p.locator('iframe')],
      ['31-preview-xlsx', 'sample_budget_xlsx', (p) => p.getByRole('tab').first()],
      ['32-preview-pptx', 'sample_deck_pptx', (p) => p.locator('iframe')],
      ['33-preview-zip', 'sample_bundle_zip', (p) => p.getByRole('button', { name: 'notes.md' })],
      ['34-preview-no-renderer', 'sample_design_fig', (p) => p.getByText('There is no preview')],
      ['35-preview-failed', 'sample_broken_pdf', (p) => p.getByText("This preview didn't work.")],
      ['36-preview-log', 'sample_server_log', (p) => p.locator('.cm-content')],
    ]
    test('previews: every type in the slide-over, and full screen', async ({ page }) => {
      test.setTimeout(120_000)
      for (const [name, key, ready] of previews) {
        await page.goto(idUrl(node(key)))
        const panel = slideOver(page)
        await expect(ready(panel)).toBeVisible({ timeout: 30_000 })
        await page.waitForTimeout(600)
        await shot(page, name)
      }
      await page.goto(idUrl(node('sample_report_pdf')))
      await expect(slideOver(page).locator('canvas')).toBeVisible({ timeout: 30_000 })
      await slideOver(page).getByRole('button', { name: 'Full screen' }).click()
      await shot(page, '37-preview-full-screen')
    })

    test('exact view: offer, download and the engine window', async ({ page, context }) => {
      test.skip(phone, 'exact view is not offered on a phone')
      test.setTimeout(180_000)
      await page.route('**/localhost:4622/**', async (route) => {
        if (!route.request().url().endsWith('manifest.json')) await new Promise((r) => setTimeout(r, 2500))
        await route.continue().catch(() => {})
      })
      await page.goto(idUrl(node('sample_plan_docx')))
      const panel = slideOver(page)
      await expect(panel.getByText(/Downloading exact view/)).toBeVisible({ timeout: 30_000 })
      await shot(page, '38-exact-view-downloading')
      await page.unroute('**/localhost:4622/**')
      const popup = context.waitForEvent('page')
      await panel.getByRole('button', { name: 'Show exact view' }).click({ timeout: 150_000 })
      const win = await popup
      await win.setViewportSize({ width: 320, height: 110 })
      await win.screenshot({ path: path.join(OUT, size.name, '39-engine-window.png') })
      await expect(panel.getByText(/^Exact view, made on this device$/)).toBeVisible({ timeout: 150_000 })
      await shot(page, '40-exact-view-shown')
    })

    test('pages: editor, slash menu, history', async ({ page }) => {
      await page.goto(idUrl(node('launch_plan')))
      await expect(page.locator('article .ProseMirror h2').first()).toBeVisible()
      await shot(page, '41-page-editor')
      const n = (await api('e2e_owner').post('/nodes', { parent_id: node('owner_c').id, name: 'Meeting notes', kind: 'page', on_conflict: 'keep_both' })).node
      await page.goto(idUrl({ name: n.name, short_id: n.short_id }))
      await page.locator('article .ProseMirror').click()
      await page.keyboard.type('/')
      await expect(page.getByRole('menu', { name: 'Insert a block' })).toBeVisible()
      await shot(page, '42-page-slash-menu')
      await page.keyboard.press('Escape')
      await page.goto(idUrl(node('launch_plan')))
      await page.getByRole('button', { name: 'History', exact: true }).click()
      await expect(slideOver(page).locator('li').first()).toBeVisible()
      await slideOver(page).locator('li').first().getByRole('button').first().click()
      await shot(page, '43-page-history')
    })

    test('public link viewer: locked, unlocked, folder, not found', async ({ browser }) => {
      const ctx = await browser.newContext({ viewport: size.viewport })
      const page = await ctx.newPage()
      await page.goto(seed.links.password.path)
      await expect(page.getByRole('heading', { name: 'This link has a password' })).toBeVisible()
      await shot(page, '44-public-locked')
      await page.getByLabel('Password').fill('open-sesame')
      await page.getByRole('button', { name: 'Open' }).click()
      await expect(page.locator('canvas').first()).toBeVisible({ timeout: 30_000 })
      await shot(page, '45-public-unlocked-pdf')
      await page.goto(seed.links.folder.path)
      await expect(page.getByRole('navigation', { name: 'Folder' })).toBeVisible()
      await shot(page, '46-public-folder')
      await page.goto(seed.links.revoked.path)
      await expect(page.getByRole('alert')).toBeVisible()
      await shot(page, '47-public-not-found')
      await ctx.close()
    })

    test('console: Disk page, agents card, offboarding dialog', async ({ page }) => {
      await page.goto('/console/disk')
      await expect(page.getByRole('heading', { name: 'Space' })).toBeVisible()
      await shot(page, '48-console-disk')
      await page.getByRole('region', { name: 'E2E Agent' }).scrollIntoViewIfNeeded()
      await shot(page, '49-console-agents')
      await page.goto('/console/people')
      const ben = page.getByRole('row').filter({ hasText: 'Ben Member' }).or(page.locator('[class*="person" i]').filter({ hasText: 'Ben Member' })).first()
      await api('e2e_ben').upload((await api('e2e_ben').get('/')).c_drive.id, 'ben-notes.md', '# Ben\n').catch(() => {})
      await ben.getByRole('button', { name: 'Actions' }).click()
      await page.getByText('Remove', { exact: true }).click()
      await page.getByRole('dialog').getByRole('button', { name: 'Remove member' }).click()
      await page.getByRole('dialog').last().getByRole('button', { name: 'Remove member' }).click()
      await expect(page.getByRole('group', { name: 'Their Disk files' })).toBeVisible()
      await shot(page, '50-offboarding-dialog')
    })

    test('plan states: paywall, read-only, full', async ({ as }) => {
      const fran = await as('e2e_free', { viewport: size.viewport })
      await fran.goto(diskUrl('', 'e2e-nodisk'))
      await expect(fran.getByRole('heading', { name: "Disk isn't in your plan" })).toBeVisible()
      await shot(fran, '51-paywall')
      const rory = await as('e2e_ro', { viewport: size.viewport })
      await rory.goto(diskUrl('c', 'e2e-readonly'))
      await expect(rory.getByText(/Your plan no longer includes Disk/)).toBeVisible()
      await shot(rory, '52-read-only-banner')
      const felix = await as('e2e_full', { viewport: size.viewport })
      await felix.goto(diskUrl('c', 'e2e-full'))
      await expect(felix.getByText(/Disk is full/)).toBeVisible()
      await shot(felix, '53-full-banner')
    })

    test('mail: Save to Disk and the composer\'s From Disk', async ({ page }) => {
      test.skip(phone, 'the phone mail client is a different app (MobileMail); Disk in it is not covered here')
      await page.goto('/e2e-disk/mail')
      await page.getByText('Quarterly figures').first().click()
      const chip = page.getByRole('button', { name: /figures\.csv/ }).first()
      await chip.click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Save to Disk…' }).click()
      await page.getByRole('dialog').getByRole('button', { name: /^C:\\/ }).click()
      await shot(page, '54-mail-save-to-disk')
      await page.keyboard.press('Escape')
      await page.getByRole('button', { name: /Compose/ }).first().click()
      await page.getByRole('button', { name: 'From Disk' }).click()
      await page.getByRole('dialog').getByRole('button', { name: /^Marketing/ }).click()
      await page.getByRole('dialog').getByRole('button', { name: /^Samples/ }).click()
      await shot(page, '55-composer-from-disk')
    })

    test('sealed: create with the warning, unlock, listing, key holders, rotate with links, rotation due, link viewer, page, cross-seal, limits', async ({ browser, as }) => {
      test.setTimeout(240_000)
      const sol = await as('e2e_sol', { viewport: size.viewport })
      // The create dialog, warning first (a fresh browser has not acknowledged it).
      await sol.goto(surl('d'))
      await unlockIn(sol)
      await newSealedShareMenu(sol)
      await sol.getByRole('dialog').getByLabel('Name').fill('Board papers')
      await expect(sol.getByRole('dialog')).toContainText('lost for good')
      await shot(sol, '56-sealed-create-warning')
      await sol.keyboard.press('Escape')
      const share = await newSealedShare(sol, `Board ${size.name}`)
      await uploadHere(sol, [sample('report.pdf'), sample('photo.jpg'), sample('notes.md')])
      await shot(sol, '57-sealed-listing')
      // Unlock prompt in a fresh session.
      const fresh = await as('e2e_sol', { viewport: size.viewport })
      await fresh.goto(surl(`d/${share.slug}`))
      await expect(fresh.getByLabel('Your inbox2 password')).toBeVisible()
      await shot(fresh, '58-sealed-unlock-prompt')
      // A link, then key holders and the remove confirmation that lists it.
      await row(sol, 'report.pdf').click({ button: 'right' })
      await sol.getByRole('menuitem', { name: 'Public link...' }).click()
      await sol.getByRole('dialog').getByLabel('Password (optional)').fill('board-pass')
      await sol.getByRole('dialog').getByRole('button', { name: 'Make link' }).click()
      const link = await sol.getByRole('dialog').getByRole('textbox', { name: 'Link' }).inputValue()
      await shot(sol, '59-sealed-link-dialog')
      await sol.keyboard.press('Escape')
      await addHolder(sol, share.name, 'Sam Holder')
      await sol.goto(surl('d'))
      await unlockIn(sol)
      await tile(sol, share.name).click({ button: 'right' })
      await sol.getByRole('menuitem', { name: 'Members' }).click()
      await expect(sol.getByRole('dialog').locator('li').filter({ hasText: 'Sam Holder' })).toBeVisible()
      await shot(sol, '60-sealed-key-holders')
      await sol.getByRole('dialog').locator('li').filter({ hasText: 'Sam Holder' }).getByRole('button', { name: 'Remove' }).click()
      await expect(sol.getByRole('dialog').last()).toContainText('Public links to files in here')
      await shot(sol, '61-sealed-rotate-with-links')
      await sol.keyboard.press('Escape')
      await sol.keyboard.press('Escape')
      // The link viewer, locked and unlocked.
      const ctx = await browser.newContext({ viewport: size.viewport })
      const v = await ctx.newPage()
      const u = new URL(link)
      await v.goto(u.pathname + u.hash)
      await expect(v.getByLabel('Password')).toBeVisible()
      await shot(v, '62-sealed-link-locked')
      await v.getByLabel('Password').fill('board-pass')
      await v.getByRole('button', { name: 'Open' }).click()
      await expect(v.locator('canvas').first()).toBeVisible({ timeout: 30_000 })
      await shot(v, '63-sealed-link-unlocked')
      await ctx.close()
      // A sealed page.
      await openShare(sol, share)
      await newItem(sol, 'Page')
      await sol.locator('article .ProseMirror').click()
      await sol.keyboard.type('Minutes, sealed in the browser.')
      await shot(sol, '64-sealed-page')
      // Cross-seal: moving a plain file in asks first, then shows progress.
      const c = (await sapi('e2e_sol').get('/')).c_drive.id
      await sapi('e2e_sol').upload(c, `agenda-${size.name}.md`, '# agenda\n')
      await sol.goto(surl('c'))
      await unlockIn(sol)
      await row(sol, `agenda-${size.name}.md`).click({ button: 'right' })
      await sol.getByRole('menuitem', { name: 'Move to...' }).click()
      await sol.getByRole('dialog').getByRole('button', { name: new RegExp(`^${share.name}`) }).click()
      await sol.getByRole('dialog').getByRole('button', { name: 'Move here' }).click()
      const cross = sol.getByRole('dialog').filter({ hasText: 'Move into a sealed folder?' })
      await expect(cross).toBeVisible()
      await shot(sol, '65-cross-seal-confirm')
      await cross.getByRole('button', { name: 'Move' }).click()
      await expect(cross.getByRole('status')).toContainText('1 of 1 done', { timeout: 60_000 })
      await shot(sol, '66-cross-seal-done')
      await cross.getByRole('button', { name: 'Close' }).click()
      // Rotation due: a holder leaves the org.
      const frozen = await newSealedShare(sol, `Frozen ${size.name}`)
      const [leaverName, leaver] = phone ? ['Lia Leaving', 'e2e_lia'] : ['Lou Leaving', 'e2e_lou']
      await addHolder(sol, frozen.name, leaverName)
      await fetch(`${RAILS}/api/v1/admin/users/${seed.users[leaver].id}/status`, {
        method: 'PATCH', headers: { Authorization: `Bearer ${seed.users.e2e_sol.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'disabled', scope: 'membership', org_id: seed.orgs['e2e-seal'].id }),
      })
      await openShare(sol, frozen)
      await expect(sol.getByText('A key holder left')).toBeVisible()
      await shot(sol, '68-sealed-rotation-due')
      void waitOpen
    })

    test('import: sources, list with progress and a pause, report', async ({ page }) => {
      await page.route(/accounts\.google\.com|login\.microsoftonline\.com|www\.dropbox\.com/, (route) => route.abort())
      await page.goto(diskUrl('import'))
      await expect(page.getByText('Sales library')).toBeVisible()
      await shot(page, '69-import-sources-and-list')
      await page.getByText('Dropbox', { exact: true }).last().scrollIntoViewIfNeeded()
      await shot(page, '70-import-paused')
      await page.locator('li').filter({ has: page.getByText('Sales library', { exact: true }) }).getByRole('button', { name: 'Report' }).click()
      await expect(page.getByRole('dialog')).toContainText('OneNote')
      await shot(page, '71-import-report')
    })
    void share
  })
}
