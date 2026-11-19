import { execFileSync } from 'node:child_process'
import { API, railsEnv } from './env.js'
import { test, expect, api, auth, crumbs, sample, seed, diskUrl, folderUrl, idUrl, listed, node, openFolder, row, rows, scratch, share, shareUrl, slideOver, tile, uniq } from './support.js'

/* F1. Drives and navigation (docs/plans/disk-spec.md). Each test is named after
 * the spec box it proves. */

test.describe('F1 drives and navigation', () => {
  test('F1.1 Disk opens at /disk with C:\\ and D:\\ in the sidebar; reload keeps the folder; an old /:slug/disk URL redirects @smoke', async ({ page }) => {
    // The /<slug>/disk redirect was removed on purpose in 58a4b8c7.
    await page.goto('/disk')
    await expect(page).toHaveURL(/\/disk\/c$/)
    const side = page.getByRole('navigation', { name: 'Disk' })
    await expect(side.getByRole('link', { name: /My disk\s*C:\\/ })).toBeVisible()
    await expect(side.getByRole('link', { name: /Shared disk\s*D:\\/ })).toBeVisible()
    await expect(page.getByRole('heading', { level: 1, name: 'My disk' })).toBeVisible()

    await row(page, 'Clients').getByRole('button', { name: 'Clients' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Clients' })).toBeVisible()
    const url = page.url()
    await page.reload()
    await expect(page.getByRole('heading', { level: 1, name: 'Clients' })).toBeVisible()
    expect(page.url()).toBe(url)
    await expect(row(page, 'Acme')).toBeVisible()
  })

  test('F1.2 D:\\ shows the member\'s shares as tiles; a share they are not in is absent and its URL is not found', async ({ page, as }) => {
    await page.goto(diskUrl('d'))
    await expect(page.getByRole('heading', { level: 1, name: 'Shared disk' })).toBeVisible()
    for (const name of ['Marketing', 'Finance', 'Handbook']) await expect(tile(page, name)).toBeVisible()
    await expect(tile(page, 'Marketing')).toContainText('3 members')
    await expect(tile(page, 'Handbook')).toContainText('open to everyone')
    await expect(tile(page, 'Marketing').locator('svg').first()).toBeVisible()

    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('d'))
    await expect(tile(ana, 'Marketing')).toBeVisible()
    await expect(tile(ana, 'Handbook')).toBeVisible() // open to the org
    await expect(tile(ana, 'Finance')).toHaveCount(0)
    await ana.goto(shareUrl('Finance'))
    await expect(ana.getByRole('alert')).toContainText('Not found')
    await ana.goto(idUrl({ name: 'Finance', short_id: share('Finance').root_id.slice(-21) }))
    await expect(ana.getByRole('alert')).toContainText('Not found')
  })

  test('F1.3 breadcrumbs show the DOS path, every segment navigates, deep paths fold, back returns', async ({ page }) => {
    await page.goto(idUrl(node('deep')))
    await expect(page.getByRole('heading', { level: 1, name: 'Invoices' })).toBeVisible()
    const nav = crumbs(page)
    await expect(nav).toContainText('C:\\')
    await expect(nav.getByRole('button', { name: 'Invoices' })).toHaveAttribute('aria-current', 'location')
    // The path is corrected to the readable form (the id is the authority).
    await expect(page).toHaveURL(/\/disk\/c\/Clients\/Acme\/2026\/Q1\/Invoices-/)

    // Deep: on a narrow bar the middle folds into a menu.
    await page.setViewportSize({ width: 390, height: 844 })
    const more = nav.getByRole('button', { name: /more folders/ })
    await expect(more).toBeVisible()
    await more.click()
    await page.getByRole('menuitem', { name: 'Acme' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Acme' })).toBeVisible()
    await page.setViewportSize({ width: 1440, height: 900 })
    await page.goBack()
    await expect(page.getByRole('heading', { level: 1, name: 'Invoices' })).toBeVisible()
    await crumbs(page).getByRole('button', { name: 'C:\\' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'My disk' })).toBeVisible()
    await page.goBack()
    await expect(page.getByRole('heading', { level: 1, name: 'Invoices' })).toBeVisible()

    // A share path: D:\Marketing\Launch 2026, each segment clickable.
    await page.goto(idUrl(node('hero_folder')))
    await expect(crumbs(page)).toContainText('D:\\')
    await expect(crumbs(page)).toContainText('Marketing')
    await expect(page).toHaveURL(new RegExp(`/disk/d/${share('Marketing').slug}/Launch%202026/Assets/Hero-`))
    await crumbs(page).getByRole('button', { name: 'Marketing' }).click()
    await expect(page.getByRole('heading', { level: 1, name: 'Marketing' })).toBeVisible()
    await expect(page).toHaveURL(new RegExp(`/disk/d/${share('Marketing').slug}$`))
  })

  test('F1.4 the list sorts by each column; by size the largest comes first and folders stay above files', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await listed(page)
    const names = () => rows(page).locator('td:nth-child(2) button').allInnerTexts()
    await page.getByRole('columnheader', { name: 'Size' }).getByRole('button').click()
    await expect(page.getByRole('columnheader', { name: 'Size' })).toHaveAttribute('aria-sort', /descending/)
    await expect.poll(async () => (await names())[0]).toMatch(/deck\.pptx|clip\.mp4/)
    const sizes = await rows(page).locator('td:last-child').allInnerTexts()
    const bytes = (s) => { const m = /([\d.]+)\s*(B|KB|MB)/.exec(s); return m ? Number(m[1]) * { B: 1, KB: 1024, MB: 1024 ** 2 }[m[2]] : 0 }
    const asBytes = sizes.map(bytes)
    expect([...asBytes].sort((a, b) => b - a)).toEqual(asBytes)
    for (const col of ['Name', 'Modified', 'By']) {
      await page.getByRole('columnheader', { name: col }).getByRole('button').click()
      await expect(page.getByRole('columnheader', { name: col })).toHaveAttribute('aria-sort', /ascending|descending/)
    }

    // Folders stay grouped above files whatever the sort.
    await openFolder(page, idUrl({ name: 'Launch 2026', short_id: node('launch').short_id }), 'Launch 2026')
    await page.getByRole('columnheader', { name: 'Size' }).getByRole('button').click()
    await expect(rows(page).first()).toContainText('Assets')
    await expect(rows(page).last()).toContainText('brief.md')
  })

  test('F1.5 Shared with me, Recent, Starred and Trash views', async ({ page, as }) => {
    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('shared-with-me'))
    await expect(ana.getByRole('heading', { level: 1, name: 'Shared with me' })).toBeVisible()
    await expect(row(ana, 'For Ana')).toBeVisible()

    // Starring a file adds it to Starred.
    const name = `${uniq('star')}.md`
    await api('e2e_ana').upload(node('ana_c').id, name, '# star me\n')
    await ana.goto(diskUrl('c'))
    await row(ana, name).click({ button: 'right' })
    await ana.getByRole('menuitem', { name: 'Star', exact: true }).click()
    await ana.goto(diskUrl('starred'))
    await expect(row(ana, name)).toBeVisible()

    // A previewed file appears in Recent.
    await page.goto(idUrl(node('launch_brief')))
    await expect(slideOver(page)).toBeVisible()
    await page.goto(diskUrl('recent'))
    await expect(row(page, 'brief.md')).toBeVisible()

    await page.goto(diskUrl('trash'))
    await expect(page.getByRole('heading', { level: 1, name: 'Trash' })).toBeVisible()
  })

  test('F1.6 a click selects, the name or a double click opens, Cmd and Shift extend, Esc clears', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await listed(page)
    const r = (name) => row(page, name)
    // Date cell: selects, opens nothing.
    await r('notes.md').locator('td').nth(2).click()
    await expect(page.getByText('1 selected')).toBeVisible()
    await expect(page).not.toHaveURL(/open=/)
    await expect(r('notes.md')).toHaveClass(/picked/)
    // Cmd or Ctrl adds one; again removes it.
    const mod = process.platform === 'darwin' ? 'Meta' : 'Control'
    await r('data.csv').locator('td').nth(2).click({ modifiers: [mod] })
    await expect(page.getByText('2 selected')).toBeVisible()
    await r('data.csv').locator('td').nth(2).click({ modifiers: [mod] })
    await expect(page.getByText('1 selected')).toBeVisible()
    // Shift selects the range.
    const all = await rows(page).count()
    await rows(page).first().locator('td').nth(2).click()
    await rows(page).nth(3).locator('td').nth(2).click({ modifiers: ['Shift'] })
    await expect(page.getByText('4 selected')).toBeVisible()
    expect(all).toBeGreaterThan(4)
    // Esc clears; so does a click on empty space.
    await page.keyboard.press('Escape')
    await expect(page.getByText(/\d+ selected/)).toHaveCount(0)
    await r('notes.md').locator('td').nth(2).click()
    await expect(page.getByText('1 selected')).toBeVisible()
    await page.locator('main h1').click() // empty space on the page
    await expect(page.getByText(/\d+ selected/)).toHaveCount(0)
    // The name opens the preview; a double click on the size cell does too.
    await r('notes.md').getByRole('button', { name: 'notes.md' }).click()
    await expect(page).toHaveURL(/open=notes\.md-/)
    await expect(slideOver(page)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page).not.toHaveURL(/open=/)
    await r('data.csv').locator('td').last().dblclick()
    await expect(page).toHaveURL(/open=data\.csv-/)
    await expect(slideOver(page)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page).not.toHaveURL(/open=/)

    // Grid tiles follow the same model.
    await page.getByRole('button', { name: 'Grid view' }).click()
    const t = page.getByRole('listbox', { name: 'Items' }).getByRole('option').filter({ hasText: 'notes.md' })
    await t.locator('small').click()
    await expect(t).toHaveAttribute('aria-selected', 'true')
    await expect(page).not.toHaveURL(/open=/)
    await page.getByRole('button', { name: 'List view' }).click()

    // Share tiles on D:\ too.
    await page.goto(diskUrl('d'))
    await tile(page, 'Marketing').locator('small').click()
    await expect(tile(page, 'Marketing')).toHaveAttribute('aria-selected', 'true')
    await expect(page).toHaveURL(new RegExp(`${diskUrl('d')}$`))
  })

  test('F1.7 right-click opens our menu with the actions for what is under the pointer', async ({ page, as }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await listed(page)
    const menu = page.getByRole('menu')
    const items = async () => (await menu.getByRole('menuitem').allInnerTexts()).map((t) => t.split('\n')[0].trim())

    // A file: right-clicking an unselected row selects it first.
    await row(page, 'notes.md').click({ button: 'right' })
    await expect(menu).toBeVisible()
    await expect(page.getByText('1 selected')).toBeVisible()
    expect(await items()).toEqual(expect.arrayContaining(['Preview', 'Open full screen', 'Download', 'Share...', 'Copy link', 'Rename', 'Move to...', 'Make a copy', 'Star', 'Versions', 'Delete']))
    await expect(menu.getByRole('menuitem').first()).toBeFocused()
    await page.keyboard.press('ArrowDown')
    await expect(menu.getByRole('menuitem').nth(1)).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(menu).toHaveCount(0)

    // Several selected: a count and the bulk actions.
    const mod = process.platform === 'darwin' ? 'Meta' : 'Control'
    await row(page, 'data.csv').locator('td').nth(2).click({ modifiers: [mod] })
    await row(page, 'data.csv').click({ button: 'right' })
    await expect(menu).toBeVisible()
    await expect(menu).toContainText('2 items selected')
    expect(await items()).toEqual(expect.arrayContaining(['Download as zip', 'Share...', 'Move to...', 'Delete 2 items']))
    await page.keyboard.press('Escape')
    await page.keyboard.press('Escape')

    // A folder: open, share, copy link, zip, rename, move, star, delete.
    await openFolder(page, idUrl(node('launch')), 'Launch 2026')
    // Empty space under a short list: new folder, new page, upload, select all.
    const box = await page.locator('[aria-busy]').first().boundingBox()
    await page.mouse.click(box.x + box.width / 2, box.y + box.height - 4, { button: 'right' })
    await expect(menu).toBeVisible()
    expect(await items()).toEqual(expect.arrayContaining(['New folder', 'New page', 'Upload files', 'Select all']))
    await page.keyboard.press('Escape')
    await row(page, 'Assets').click({ button: 'right' })
    await expect(menu).toBeVisible()
    expect(await items()).toEqual(expect.arrayContaining(['Open', 'Share...', 'Copy link', 'Download as zip', 'Rename', 'Move to...', 'Star', 'Delete']))
    await page.keyboard.press('Escape')

    // Near the right and bottom edges the menu stays on screen.
    const vp = page.viewportSize()
    await row(page, 'brief.md').click({ button: 'right', position: { x: 2, y: 2 } })
    await page.mouse.click(vp.width - 3, vp.height - 3, { button: 'right' }).catch(() => {})
    if (await menu.isVisible()) {
      const b = await menu.boundingBox()
      expect(b.x + b.width).toBeLessThanOrEqual(vp.width)
      expect(b.y + b.height).toBeLessThanOrEqual(vp.height)
      await page.keyboard.press('Escape')
    }

    // A viewer's menu has no write actions.
    const vic = await as('e2e_vic')
    await openFolder(vic, idUrl(node('samples')), 'Samples')
    await row(vic, 'notes.md').click({ button: 'right' })
    await expect(vic.getByRole('menu')).toBeVisible()
    const vicItems = (await vic.getByRole('menu').getByRole('menuitem').allInnerTexts()).map((t) => t.split('\n')[0].trim())
    expect(vicItems).toContain('Download')
    for (const absent of ['Rename', 'Move to...', 'Make a copy', 'Delete']) expect(vicItems).not.toContain(absent)
    await vic.keyboard.press('Escape')

    // Text fields keep the browser's own menu.
    await page.getByRole('searchbox', { name: 'Search files and folders' }).click({ button: 'right' })
    await expect(menu).toHaveCount(0)
  })

  test('F1.7 a half-second touch press opens the same menu, and a folder on C:\\ offers Seal', async ({ browser, browserName }) => {
    test.skip(browserName !== 'chromium', 'touch is driven through the Chrome DevTools protocol')
    const ctx = await browser.newContext({ storageState: auth('e2e_owner'), hasTouch: true })
    const page = await ctx.newPage()
    const f = await scratch('e2e_owner', node('owner_c').id, 'f1-touch')
    await api('e2e_owner').folder(f.id, 'Inside')
    await openFolder(page, folderUrl(f), f.name)
    await listed(page)
    const box = await row(page, 'Inside').locator('td').nth(2).boundingBox()
    const cdp = await ctx.newCDPSession(page)
    const point = { x: box.x + box.width / 2, y: box.y + box.height / 2 }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point] })
    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible({ timeout: 3000 }) // opens while the finger is still down
    const items = (await menu.getByRole('menuitem').allInnerTexts()).map((t) => t.split('\n')[0].trim())
    expect(items).toEqual(expect.arrayContaining(['Open', 'Share...', 'Download as zip', 'Rename', 'Seal...', 'Delete']))
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
    // The press neither opened the folder nor left the browser's own menu.
    await expect(page.locator('main h1')).toHaveText(f.name)
    await ctx.close()
  })

  test('F1 Disk is on one org at a time: a switcher for someone in several, remembered, closing the phone drawer, and a link into the other org switches to it', async ({ browser }) => {
    execFileSync('bin/rails', ['e2e:disk:join'], { cwd: API, env: { ...railsEnv(), USER_NAME: 'e2e_new', ORG: 'e2e-other' } })
    const ctx = await browser.newContext({ storageState: auth('e2e_new'), viewport: { width: 390, height: 844 } })
    const page = await ctx.newPage()
    await page.goto('/disk/c')
    const menuBtn = page.getByRole('button', { name: 'Drives and views' })
    // Each team is a lettered drive in the sidebar (f2791d0c); the org select is gone.
    const nav = page.getByRole('navigation', { name: 'Disk' })
    const team = (name) => nav.getByRole('link', { name: new RegExp(name) })
    await menuBtn.click()
    await expect(team('E2E Disk Co')).toBeVisible()
    await team('Other Tenant').click()
    await expect(page).toHaveURL(/\/disk\/[e-z]$/)
    await expect(menuBtn).toBeFocused() // the drawer closed over the new org
    await expect(menuBtn).toHaveAttribute('aria-expanded', 'false')
    // Remembered in this browser: its shares sit under its drive, even from C:\.
    await page.goto('/disk/c')
    await menuBtn.click()
    await expect(nav.getByRole('link', { name: 'Other Share' })).toBeVisible()
    await team('E2E Disk Co').click()
    await expect(page).toHaveURL(/\/disk\/d$/)
    // A pasted link to a share in the other org: looked up there, Disk switches.
    await page.goto(diskUrl(`d/${seed.shares['Other Share'].slug}`))
    await expect(page.getByRole('heading', { level: 1, name: 'Other Share' })).toBeVisible()
    expect(new URL(page.url()).pathname).toMatch(new RegExp(`^/disk/[d-z]/${seed.shares['Other Share'].slug}$`))
    await menuBtn.click()
    await expect(nav.getByRole('link', { name: 'Other Share' })).toBeVisible()
    await ctx.close()
  })

  test('F1.8 loading shows skeletons shaped like the content, and nothing shifts when it lands', async ({ page }) => {
    // Layout shift is measured from the first paint (buffered).
    await page.addInitScript(() => {
      window.__cls = 0
      new PerformanceObserver((l) => { for (const e of l.getEntries()) if (!e.hadRecentInput) window.__cls += e.value }).observe({ type: 'layout-shift', buffered: true })
    })
    // Hold the folder listing back so the skeleton has time to show.
    let release
    const gate = new Promise((r) => { release = r })
    await page.route('**/disk/nodes/*/children*', async (route) => { await gate; await route.continue() })
    await page.goto(idUrl(node('deep')))
    const skeleton = page.locator('table[aria-hidden="true"], [aria-hidden="true"] > table').first()
    await expect(page.locator('[class*="skRow"]').first()).toBeVisible()
    await expect(page.locator('[class*="spinner" i]')).toHaveCount(0) // never a full-area spinner
    const skBox = await skeleton.boundingBox()
    const skCols = await page.locator('[class*="skRow"]').first().locator('td').evaluateAll((tds) => tds.map((td) => Math.round(td.getBoundingClientRect().width)))
    const before = await page.evaluate(() => window.__cls)
    release()
    await expect(row(page, 'invoice-001.pdf')).toBeVisible()
    await page.waitForTimeout(400)
    const real = await page.locator('table').first().boundingBox()
    const realCols = await rows(page).first().locator('td').evaluateAll((tds) => tds.map((td) => Math.round(td.getBoundingClientRect().width)))
    expect(Math.abs(real.x - skBox.x)).toBeLessThan(2)
    expect(Math.abs(real.y - skBox.y)).toBeLessThan(2)
    expect(Math.abs(real.width - skBox.width)).toBeLessThan(2)
    expect(realCols).toEqual(skCols)
    // The shift when the data lands is zero.
    expect(await page.evaluate(() => window.__cls) - before).toBeLessThan(0.001)
    await page.unroute('**/disk/nodes/*/children*')

    // D:\ tiles have their skeleton twin while the drives load.
    let release2
    const gate2 = new Promise((r) => { release2 = r })
    await page.route(/\/disk$/, async (route) => { await gate2; await route.continue() })
    await page.goto(diskUrl('d'))
    await expect(page.locator('[class*="tile" i][aria-hidden="true"], [aria-hidden="true"] [class*="tile" i]').first()).toBeVisible()
    release2()
    await expect(tile(page, 'Marketing')).toBeVisible()
    await page.unroute(/\/disk$/)
  })

  test('F1.9 moving between folders keeps the previous list until the next lands; a fast load shows no skeleton', async ({ page }) => {
    await page.goto(diskUrl('c'))
    await expect(row(page, 'Clients')).toBeVisible()
    let release
    const gate = new Promise((r) => { release = r })
    await page.route('**/disk/nodes/*/children*', async (route) => { await gate; await route.continue() })
    await row(page, 'Clients').getByRole('button', { name: 'Clients' }).click()
    // Breadcrumbs update at once (the click hands the path along).
    await expect(crumbs(page)).toContainText('Clients')
    release()
    await expect(row(page, 'Acme')).toBeVisible()
    await page.unroute('**/disk/nodes/*/children*')

    // A load under 150 ms: no skeleton frame ever appears.
    await page.goto(diskUrl('c'))
    await expect(row(page, 'Clients')).toBeVisible()
    await page.evaluate(() => {
      window.__sk = false
      new MutationObserver(() => { if (document.querySelector('[class*="skRow"],[class*="skTile"]')) window.__sk = true }).observe(document.body, { subtree: true, childList: true })
    })
    await row(page, 'For Ana').getByRole('button', { name: 'For Ana' }).click()
    await expect(row(page, 'Drafts')).toBeVisible()
    expect(await page.evaluate(() => window.__sk)).toBe(false)
  })

  test('F1.8 search results, the slide-over, the share dialog and the console show skeletons while they load, never a spinner', async ({ page }) => {
    const spinners = () => page.locator('[class*="spinner" i], [role="progressbar"]').count()
    const hold = async (pattern, run) => {
      let release
      const gate = new Promise((r) => { release = r })
      await page.route(pattern, async (route) => { await gate; await route.continue().catch(() => {}) })
      try { await run() } finally { release(); await page.unroute(pattern) }
    }
    const skeleton = (scope) => scope.locator('[aria-hidden="true"]').filter({ has: page.locator('span') }).first()
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await listed(page)
    // Search results.
    await hold('**/disk/search*', async () => {
      await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('zz-nothing-loads-yet')
      // ponytail: by design (useDiskListing, build guide section 3) the previous list stays, dimmed, until results land;
      // a skeleton shows only with nothing to dim. The spec's "search results skeleton" needs a decision.
      await expect(row(page, 'report.pdf')).toBeVisible()
      expect(await spinners()).toBe(0)
    })
    await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('')
    await listed(page)
    // The slide-over, while the file's details load.
    await hold(/\/disk\/nodes\/[^/?]+$/, async () => {
      await row(page, 'report.pdf').getByRole('button', { name: /^report\.pdf/ }).click()
      await expect(skeleton(slideOver(page))).toBeVisible()
      expect(await spinners()).toBe(0)
    })
    await page.keyboard.press('Escape')
    // The share dialog, while who has access loads.
    await hold('**/grants*', async () => {
      await row(page, 'notes.md').click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Share...' }).click()
      await expect(skeleton(page.getByRole('dialog'))).toBeVisible()
      expect(await spinners()).toBe(0)
    })
    await page.keyboard.press('Escape')
    // The console's Disk page.
    await hold('**/disk/admin/usage', async () => {
      await page.goto('/console/disk')
      await expect(skeleton(page.locator('main'))).toBeVisible()
      expect(await spinners()).toBe(0)
    })
    await expect(page.getByRole('heading', { name: 'Export shares' })).toBeVisible()
  })

  test('F1.9 the slide-over shows the blurred thumbnail until the preview renders; reduced motion drops the fades and slides', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: auth('e2e_owner'), reducedMotion: 'reduce' })
    const page = await ctx.newPage()
    const f = await scratch('e2e_owner', node('owner_c').id, 'f1-thumb')
    await openFolder(page, folderUrl(f), f.name)
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(sample('photo.jpg'))
    await expect.poll(async () => (await api('e2e_owner').get(`/nodes/${f.id}/children`)).nodes[0]?.has_thumbnail, { timeout: 20_000 }).toBe(true)
    await page.reload()
    await listed(page)
    // Hold the image itself (not its thumbnail) at storage, so the preview cannot render yet.
    let release
    const gate = new Promise((r) => { release = r })
    await page.route((url) => url.port === '4900' && !url.pathname.includes('thumbnail'), async (route) => { await gate; await route.continue() })
    await row(page, 'photo.jpg').getByRole('button', { name: /^photo\.jpg/ }).click()
    const panel = slideOver(page)
    const thumb = panel.locator('[aria-hidden="true"] img')
    await expect(thumb).toBeVisible()
    expect(await thumb.evaluate((el) => getComputedStyle(el).filter)).toMatch(/blur\(/)
    // Reduced motion: the slide-over does not slide in.
    expect(await panel.evaluate((el) => getComputedStyle(el).animationName)).toBe('none')
    release()
    await expect(panel.getByRole('img', { name: 'photo.jpg' })).toBeVisible()
    await expect(thumb).toHaveCount(0)
    // Nor do skeleton bars shimmer.
    await page.route('**/disk/nodes/*/children*', () => {})
    await page.goto(folderUrl(f))
    const bar = page.locator('main [aria-hidden="true"] span').first()
    await expect(bar).toBeVisible({ timeout: 5000 })
    expect(await bar.evaluate((el) => getComputedStyle(el).animationName)).toBe('none')
    await ctx.close()
  })

  test('F1.10 full keyboard operation: arrows, Enter, Backspace, Esc', async ({ page }) => {
    await openFolder(page, idUrl(node('launch')), 'Launch 2026')
    await listed(page)
    await rows(page).first().getByRole('button').first().focus()
    await page.keyboard.press('ArrowDown')
    await expect(page.getByText('1 selected')).toBeVisible()
    await page.keyboard.press('ArrowUp')
    await expect(rows(page).first()).toHaveClass(/picked/)
    await page.keyboard.press('Enter')
    await expect(page.getByRole('heading', { level: 1, name: 'Assets' })).toBeVisible()
    await page.locator('body').press('Backspace')
    await expect(page.getByRole('heading', { level: 1, name: 'Launch 2026' })).toBeVisible()
    await row(page, 'brief.md').getByRole('button', { name: 'brief.md' }).press('Enter')
    await expect(slideOver(page)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(slideOver(page)).toHaveCount(0)
    // "/" focuses the search box.
    await page.locator('body').press('/')
    await expect(page.getByRole('searchbox', { name: 'Search files and folders' })).toBeFocused()
  })

  test('F1.11 an empty C:\\ offers the importer prompt', async ({ as }) => {
    const nina = await as('e2e_new')
    await nina.goto(diskUrl('c'))
    const prompt = nina.getByRole('main').getByRole('link', { name: 'Import', exact: true })
    await expect(prompt).toBeVisible()
    await prompt.click()
    await expect(nina.getByRole('heading', { level: 1, name: 'Import' })).toBeVisible()
  })

  test('F1.11 an empty drive and an empty folder offer Upload, New folder and New page', async ({ page, as }) => {
    const nina = await as('e2e_new')
    await nina.goto(diskUrl('c'))
    await expect(nina.getByRole('heading', { level: 1, name: 'My disk' })).toBeVisible()
    await expect(nina.getByText(/Nothing here yet/)).toBeVisible()
    for (const b of ['Upload', 'New folder', 'New page']) await expect(nina.locator('main').getByRole('button', { name: b }).last()).toBeVisible()

    const f = await scratch('e2e_owner', node('owner_c').id, 'empty')
    await openFolder(page, folderUrl(f), f.name)
    await expect(page.getByText(/Nothing here yet/)).toBeVisible()
    for (const b of ['Upload', 'New folder', 'New page']) await expect(page.locator('main').getByRole('button', { name: b }).last()).toBeVisible()
    await api('e2e_owner').del(`/nodes/${f.id}`)
  })

  test('F1 a folder page reached by a bogus id shows the not-found screen', async ({ page }) => {
    await page.goto(diskUrl(`shared/${uniq('nope').replace(' ', '-')}-AAAAAAAAAAAAAAAAAAAAA`))
    await expect(page.getByRole('alert')).toContainText('Not found')
  })
})
