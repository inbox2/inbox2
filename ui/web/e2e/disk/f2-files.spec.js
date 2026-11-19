import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { test, expect, api, changedPair, crumbs, diskUrl, folderUrl, idUrl, listed, newItem, newMenu, node, openFolder, row, rows, sample, scratch, share, slideOver, toast, uniq, uploads } from './support.js'
import { STATE } from './env.js'

// The type filter is a dropdown of checkboxes (FilterBar TypeFilter): open it, tick one, close it.
async function pickType(page, label) {
  await page.getByRole('button', { name: /^Type:/ }).click()
  await page.getByRole('checkbox', { name: label, exact: true }).check()
  await page.keyboard.press('Escape')
}

/* F2. Files and folders. Every test works in its own uniquely named folder. */

const owner = () => api('e2e_owner')
const ownerC = () => node('owner_c').id

/** Picks files through the page's Upload button. */
async function uploadFiles(page, files) {
  const chooser = page.waitForEvent('filechooser')
  await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
  await (await chooser).setFiles(files)
}

/** Drops files on the list as a real drag would (a DataTransfer with File objects). */
async function dropFiles(page, files) {
  const dt = await page.evaluateHandle((list) => {
    const d = new DataTransfer()
    for (const f of list) d.items.add(new File([f.body], f.name, { type: f.type }))
    return d
  }, files)
  const target = page.locator('main [aria-busy]').first()
  await target.dispatchEvent('dragenter', { dataTransfer: dt })
  await target.dispatchEvent('dragover', { dataTransfer: dt })
  await target.dispatchEvent('drop', { dataTransfer: dt })
}

const sizeOf = async (orgApi) => (await orgApi.get('/')).c_quota // C:\ has its own pool (f2791d0c)

test.describe('F2 files and folders', () => {
  test('F2.1 create folders in C:\\ and in a share I can edit; a viewer has no New folder and the API refuses', async ({ page, as }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-create')
    await openFolder(page, folderUrl(f), f.name)
    await newItem(page, 'Folder')
    const field = page.getByRole('textbox', { name: /^Rename/ })
    await field.fill('Made here')
    await field.press('Enter')
    await expect(row(page, 'Made here')).toBeVisible()

    // A share where Ana can edit.
    const ana = await as('e2e_ana')
    await openFolder(ana, idUrl(node('samples')), 'Samples')
    await expect(newMenu(ana)).toBeEnabled()

    // A viewer of the share: no New folder, and the API says no.
    const vic = await as('e2e_vic')
    await openFolder(vic, idUrl(node('samples')), 'Samples')
    await listed(vic)
    await expect(newMenu(vic)).toHaveCount(0)
    await expect(vic.locator('main').getByRole('button', { name: 'Upload', exact: true })).toBeDisabled()
    const r = await api('e2e_vic').call('POST', '/nodes', { parent_id: node('samples').id, name: uniq('nope'), kind: 'folder' })
    expect(r.status).toBe(403)
  })

  test('F2.2 rename, move and copy, across drives; contents come along and a move into its own descendant is refused', async ({ page, as }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-move')
    const moving = await owner().folder(f.id, uniq('Moving'))
    const inner = await owner().folder(moving.id, 'Inner')
    await owner().upload(inner.id, 'deep.md', '# deep\n')
    await owner().upload(f.id, 'rename-me.md', '# r\n')

    await openFolder(page, folderUrl(f), f.name)
    // Rename with F2.
    await row(page, 'rename-me.md').locator('td').nth(2).click()
    await page.keyboard.press('F2')
    const field = page.getByRole('textbox', { name: /^Rename/ })
    await field.fill('renamed.md')
    await field.press('Enter')
    await expect(row(page, 'renamed.md')).toBeVisible()

    // Make a copy, then copy to another folder.
    await row(page, 'renamed.md').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Make a copy' }).click()
    await expect(row(page, 'renamed (1).md')).toBeVisible()

    // Into its own descendant: refused by the API.
    const own = await owner().call('POST', `/nodes/${moving.id}/move`, { target_id: inner.id })
    expect(own.status).toBe(422)

    // Across drives: C:\ to the Marketing share, after the warning.
    await row(page, moving.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Move to...' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: /^Marketing/ }).click()
    await dlg.getByRole('button', { name: /^Samples/ }).waitFor()
    await dlg.getByRole('button', { name: 'Move here' }).click()
    await expect(page.getByRole('heading', { name: 'Move to another drive or share?' })).toBeVisible()
    await page.getByRole('dialog').getByRole('button', { name: 'Move', exact: true }).click()
    await expect(row(page, moving.name)).toHaveCount(0)

    // It took the share's access: Ana (a member of Marketing) now reaches its contents.
    const ana = await as('e2e_ana')
    await openFolder(ana, diskUrl(`d/${share('Marketing').slug}`), 'Marketing')
    await ana.getByRole('button', { name: moving.name }).click()
    await ana.getByRole('button', { name: 'Inner' }).click()
    await expect(row(ana, 'deep.md')).toBeVisible()
    await api('e2e_ben').del(`/nodes/${moving.id}`)
  })

  test('F2.3 a name clash asks: replace makes a new version, keep both makes "a (1).pdf"', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-clash')
    await openFolder(page, folderUrl(f), f.name)
    await uploadFiles(page, [sample('report.pdf')])
    await expect(uploads(page)).toContainText('Done')
    await expect(row(page, 'report.pdf')).toBeVisible()

    await uploadFiles(page, [sample('report.pdf')])
    await expect(uploads(page).getByText('Name taken')).toBeVisible()
    await uploads(page).getByRole('button', { name: 'Replace' }).click()
    await expect.poll(async () => (await owner().get(`/nodes/${(await owner().get(`/nodes/${f.id}/children`)).nodes[0].id}/versions`)).versions.length).toBe(2)

    await uploadFiles(page, [sample('report.pdf')])
    await uploads(page).getByRole('button', { name: 'Keep both' }).click()
    await expect(row(page, 'report (1).pdf')).toBeVisible()
  })

  test('F2.4 upload by button, by dropping files on the page, and a folder with nested subfolders @smoke', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-upload')
    await openFolder(page, folderUrl(f), f.name)
    await uploadFiles(page, [sample('notes.md'), sample('photo.jpg')])
    await expect(row(page, 'notes.md')).toBeVisible()
    await expect(row(page, 'photo.jpg')).toBeVisible()

    // WebKit does not hand a script-made DataTransfer's files to a drop event, so the drop is Chromium and Firefox only.
    if (test.info().project.name !== 'webkit') {
      await dropFiles(page, [{ name: 'dropped.txt', type: 'text/plain', body: 'dropped on the list\n' }])
      await expect(row(page, 'dropped.txt')).toBeVisible()
    }

    // A folder (the folder picker; dropping a folder walks the same relativePath tree).
    const tree = path.join(STATE, 'tree', uniq('Q4').replace(' ', '-'))
    fs.mkdirSync(path.join(tree, 'Budget', 'Drafts'), { recursive: true })
    fs.writeFileSync(path.join(tree, 'top.md'), '# top\n')
    fs.writeFileSync(path.join(tree, 'Budget', 'plan.csv'), 'a,b\n1,2\n')
    fs.writeFileSync(path.join(tree, 'Budget', 'Drafts', 'draft.md'), '# draft\n')
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main [aria-busy]').first().click({ button: 'right', position: { x: 10, y: 5 } })
    await page.getByRole('menuitem', { name: 'Upload folder' }).click().catch(async () => {
      await page.keyboard.press('Escape')
    })
    await (await chooser).setFiles(tree)
    const top = path.basename(tree)
    await expect(row(page, top)).toBeVisible()
    await row(page, top).getByRole('button', { name: top }).click()
    await expect(row(page, 'top.md')).toBeVisible()
    await row(page, 'Budget').getByRole('button', { name: 'Budget' }).click()
    await expect(row(page, 'plan.csv')).toBeVisible()
    await row(page, 'Drafts').getByRole('button', { name: 'Drafts' }).click()
    await expect(row(page, 'draft.md')).toBeVisible()
  })

  test('F2.5 an upload cut off midway resumes after a reload without sending the stored parts again', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-resume')
    const big = path.join(STATE, 'big-20mb.bin')
    if (!fs.existsSync(big)) fs.writeFileSync(big, Buffer.alloc(20 * 1024 * 1024, 7))
    await openFolder(page, folderUrl(f), f.name)

    // Let the first part through, then cut the network to storage.
    let puts = 0
    await page.route('**/localhost:4900/**', async (route) => {
      if (route.request().method() !== 'PUT') return route.continue()
      puts += 1
      if (puts === 1) return route.continue()
      return route.abort('internetdisconnected')
    })
    await uploadFiles(page, [big])
    await expect.poll(async () => {
      const r = await owner().get(`/nodes/${f.id}/children`)
      return r.nodes.length
    }).toBe(1).catch(() => {}) // the node exists from the reservation on
    await expect.poll(() => puts, { timeout: 30_000 }).toBeGreaterThan(1)

    // Reload: the panel lists it as interrupted; picking the same file resumes it.
    await page.reload() // still cut: a retried PUT could otherwise finish the upload first
    await page.unroute('**/localhost:4900/**')
    await expect(uploads(page).getByText('Interrupted')).toBeVisible()
    let after = 0
    page.on('request', (r) => { if (r.method() === 'PUT' && r.url().includes(':4900/')) after += 1 })
    const chooser = page.waitForEvent('filechooser')
    await uploads(page).getByRole('button', { name: 'Choose the file to resume' }).click()
    await (await chooser).setFiles(big)
    await expect(uploads(page)).toContainText('Done', { timeout: 60_000 })
    await expect(row(page, 'big-20mb.bin')).toBeVisible()
    expect(after).toBeLessThan(3) // 3 parts of 8 MiB; the stored first part is not sent again
    const listing = await owner().get(`/nodes/${f.id}/children`)
    expect(listing.nodes.find((n) => n.name === 'big-20mb.bin').size_bytes).toBe(20 * 1024 * 1024)
  })

  test('F2.5 resuming with a file whose bytes changed (same name, size and date) starts again, and the stored file has the new bytes', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-resume-changed')
    const [first, second] = changedPair('same-20mb.bin')
    await openFolder(page, folderUrl(f), f.name)
    let puts = 0
    await page.route('**/localhost:4900/**', async (route) => {
      if (route.request().method() !== 'PUT') return route.continue()
      puts += 1
      return puts === 1 ? route.continue() : route.abort('internetdisconnected')
    })
    await uploadFiles(page, [first])
    await expect.poll(() => puts, { timeout: 30_000 }).toBeGreaterThan(1)
    await page.reload() // still cut: a retried PUT could otherwise finish the upload first
    await page.unroute('**/localhost:4900/**')
    await expect(uploads(page).getByText('Interrupted')).toBeVisible()
    let after = 0
    page.on('request', (r) => { if (r.method() === 'PUT' && r.url().includes(':4900/')) after += 1 })
    const chooser = page.waitForEvent('filechooser')
    await uploads(page).getByRole('button', { name: 'Choose the file to resume' }).click()
    await (await chooser).setFiles(second)
    await expect(uploads(page)).toContainText('The file changed since this upload started, so it started again.', { timeout: 60_000 })
    await expect(uploads(page)).toContainText('Done', { timeout: 60_000 })
    expect(after).toBeGreaterThanOrEqual(3) // every part sent again, the stored first part included
    const n = (await owner().get(`/nodes/${f.id}/children`)).nodes.filter((x) => x.name === 'same-20mb.bin')
    expect(n).toHaveLength(1)
    const { download } = await owner().get(`/nodes/${n[0].id}/download`)
    const head = Buffer.from(await (await fetch(download.url, { headers: { Range: 'bytes=0-3' } })).arrayBuffer())
    expect([...head]).toEqual([9, 9, 9, 9])
    const tail = Buffer.from(await (await fetch(download.url, { headers: { Range: `bytes=${20 * 1024 * 1024 - 4}-` } })).arrayBuffer())
    expect([...tail]).toEqual([9, 9, 9, 9])
  })

  test('F2.5 a 1 GB upload cut off midway resumes without restarting, and no file bytes pass through Rails (E2E_DISK_LARGE)', async ({ page }) => {
    test.skip(!process.env.E2E_DISK_LARGE, 'set E2E_DISK_LARGE=1 to run the 1 GB case')
    test.setTimeout(900_000)
    const f = await scratch('e2e_owner', ownerC(), 'f2-gb')
    const gb = sample('one-gb.bin')
    await openFolder(page, folderUrl(f), f.name)
    let puts = 0
    let toRails = 0
    page.on('request', (r) => { if (r.url().includes(':4621/api/')) toRails += (r.postDataBuffer()?.length || 0) })
    await page.route('**/localhost:4900/**', async (route) => {
      if (route.request().method() !== 'PUT') return route.continue()
      puts += 1
      return puts <= 60 ? route.continue() : route.abort('internetdisconnected') // about half of 128 parts
    })
    await uploadFiles(page, [gb])
    await expect.poll(() => puts, { timeout: 600_000 }).toBeGreaterThan(64)
    await page.reload() // still cut: a retried PUT could otherwise finish the upload first
    await page.unroute('**/localhost:4900/**')
    let after = 0
    page.on('request', (r) => { if (r.method() === 'PUT' && r.url().includes(':4900/')) after += 1 })
    const chooser = page.waitForEvent('filechooser')
    await uploads(page).getByRole('button', { name: 'Choose the file to resume' }).click()
    await (await chooser).setFiles(gb)
    await expect(uploads(page)).toContainText('Done', { timeout: 600_000 })
    expect(after).toBeLessThan(128) // it did not start again
    expect(toRails).toBeLessThan(1024 * 1024) // only JSON went to Rails
    const node = (await owner().get(`/nodes/${f.id}/children`)).nodes.find((n) => n.name === 'one-gb.bin')
    expect(node.size_bytes).toBe(1024 * 1024 * 1024)
  })

  test('F2.6 per-file progress with cancel; cancelling releases the reserved quota', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-cancel')
    const big = path.join(STATE, 'big-20mb.bin')
    if (!fs.existsSync(big)) fs.writeFileSync(big, Buffer.alloc(20 * 1024 * 1024, 7))
    await openFolder(page, folderUrl(f), f.name)
    // Slow storage down so the upload is still running when we cancel.
    await page.route('**/localhost:4900/**', async (route) => {
      if (route.request().method() === 'PUT') await new Promise((r) => setTimeout(r, 20_000))
      await route.continue().catch(() => {})
    })
    const base = (await sizeOf(owner())).reserved_bytes // other uploads may hold reservations of their own
    await uploadFiles(page, [big])
    await expect(uploads(page).getByText('Uploading', { exact: true })).toBeVisible()
    await expect(uploads(page).locator('meter, [role="progressbar"], [class*="meter" i]').first()).toBeVisible()
    await expect.poll(async () => (await sizeOf(owner())).reserved_bytes).toBe(base + 20 * 1024 * 1024)
    await uploads(page).getByRole('button', { name: 'Cancel big-20mb.bin' }).click()
    await page.getByRole('button', { name: 'Cancel upload' }).click() // asks first now
    await expect(uploads(page)).toContainText('Cancelled')
    await expect.poll(async () => (await sizeOf(owner())).reserved_bytes).toBe(base)
    await page.unroute('**/localhost:4900/**')
  })

  test('F2.7 download a file, and a folder as a zip built in the browser @smoke', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-download')
    const sub = await owner().folder(f.id, 'Sub')
    await owner().upload(f.id, 'one.md', '# one\n')
    await owner().upload(sub.id, 'two.md', '# two\n')
    await openFolder(page, folderUrl(f), f.name)

    const d1 = page.waitForEvent('download')
    await row(page, 'one.md').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Download', exact: true }).click()
    const file = await d1
    expect(file.suggestedFilename()).toBe('one.md')
    expect(fs.readFileSync(await file.path(), 'utf8')).toBe('# one\n')

    // The zip goes to a file the person picks where the browser can (showSaveFilePicker); a
    // headless browser cannot answer that picker, so this drives the Blob path Safari and Firefox take.
    await page.evaluate(() => { delete window.showSaveFilePicker })
    const d2 = page.waitForEvent('download')
    await row(page, 'Sub').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Download as zip' }).click()
    const zip = await d2
    expect(zip.suggestedFilename()).toBe('Sub.zip')
    const listing = execFileSync('unzip', ['-l', await zip.path()], { encoding: 'utf8' })
    expect(listing).toContain('two.md')
  })

  test('F2.8 delete moves to the trash; restore brings a folder back to its place with its contents', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-trash')
    const gone = await owner().folder(f.id, uniq('Gone'))
    await owner().upload(gone.id, 'kept.md', '# kept\n')
    await openFolder(page, folderUrl(f), f.name)
    await row(page, gone.name).locator('td').nth(2).click()
    await page.keyboard.press('Delete')
    await expect(row(page, gone.name)).toHaveCount(0)

    await page.getByRole('link', { name: 'Trash' }).click()
    await row(page, gone.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Restore' }).click()
    await expect(row(page, gone.name)).toHaveCount(0)
    await openFolder(page, folderUrl(f), f.name)
    await row(page, gone.name).getByRole('button', { name: gone.name }).click()
    await expect(row(page, 'kept.md')).toBeVisible()

    // Delete forever from the trash.
    await owner().del(`/nodes/${gone.id}`)
    await page.goto(diskUrl('trash'))
    await row(page, gone.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Delete forever' }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Delete forever' }).click()
    await expect(row(page, gone.name)).toHaveCount(0)
  })

  test('F2.9 version history: three versions, restore the first and it becomes the fourth', async ({ page }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-versions')
    const file = await owner().upload(f.id, 'history.md', '# v1\n')
    await owner().upload(f.id, 'history.md', '# v2 longer\n', { node_id: file.id, parent_id: undefined })
    await owner().upload(f.id, 'history.md', '# v3 longest yet\n', { node_id: file.id, parent_id: undefined })
    await openFolder(page, folderUrl(f), f.name)
    await row(page, 'history.md').getByRole('button', { name: 'history.md' }).click()
    const panel = slideOver(page)
    await expect(panel.getByText('Versions (kept 180 days)')).toBeVisible()
    await expect(panel.getByText(/^Version \d/)).toHaveCount(3)
    await expect(panel.getByText('Version 3, current')).toBeVisible()
    const v1 = panel.locator('li').filter({ has: page.getByText('Version 1', { exact: true }) })
    await v1.getByRole('button', { name: 'Restore' }).click()
    await expect(panel.getByText(/^Version \d/)).toHaveCount(4)
    await expect(panel.getByText('Version 4, current')).toBeVisible()
    const d = page.waitForEvent('download')
    await panel.locator('li').filter({ has: page.getByText('Version 4, current', { exact: true }) }).getByRole('button', { name: 'Download' }).click()
    expect(fs.readFileSync(await (await d).path(), 'utf8')).toBe('# v1\n')
  })

  test('F2.10 filters combine, count "2 of N", clear, and a filter with no match is not the empty-folder state', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await listed(page)
    const total = await rows(page).count()
    await pickType(page, 'Media')
    await page.getByRole('combobox', { name: 'Modified', exact: true }).selectOption({ label: 'Last 7 days' })
    await expect(rows(page)).toHaveCount(2)
    await expect(row(page, 'clip.mp4')).toBeVisible()
    await expect(row(page, 'voice.m4a')).toBeVisible()
    await expect(page.getByText(`2 of ${total} items`)).toBeVisible()
    await page.getByRole('button', { name: 'Clear filters' }).click()
    await expect(rows(page)).toHaveCount(total)
    await pickType(page, 'Pages')
    await expect(page.getByText('Nothing matches')).toBeVisible()
    await expect(page.getByText('Nothing here yet')).toHaveCount(0)
    await page.getByRole('button', { name: 'Clear filters' }).first().click()
  })

  test('F2.11 list and grid view, and the choice survives a reload', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await page.getByRole('button', { name: 'Grid view' }).click()
    const grid = page.getByRole('listbox', { name: 'Items' })
    await expect(grid.getByRole('option').filter({ hasText: 'report.pdf' })).toContainText(/KB|B/)
    await page.reload()
    await expect(page.getByRole('listbox', { name: 'Items' })).toBeVisible()
    await expect(page.getByRole('button', { name: 'Grid view' })).toHaveAttribute('aria-pressed', 'true')
    await page.getByRole('button', { name: 'List view' }).click()
    await page.reload()
    await expect(page.locator('table')).toBeVisible()
  })

  test('F2.12 select with checkboxes and act together; a refused item is reported', async ({ page, as }) => {
    const f = await scratch('e2e_owner', ownerC(), 'f2-bulk')
    for (const n of ['a.md', 'b.md', 'c.md', 'd.md']) await owner().upload(f.id, n, `# ${n}\n`)
    await openFolder(page, folderUrl(f), f.name)
    for (const n of ['a.md', 'b.md', 'c.md']) await page.getByRole('checkbox', { name: `Select ${n}` }).check()
    const bar = page.getByRole('toolbar', { name: 'Selected items' })
    await expect(bar).toContainText('3 selected')
    await expect(newMenu(page)).toHaveCount(0)
    await bar.getByRole('button', { name: 'Delete' }).click()
    await expect(rows(page)).toHaveCount(1)
    await page.getByRole('checkbox', { name: 'Select all' }).check()
    await expect(bar).toContainText('1 selected')

    // Mixed rights: Ana deletes her own file and one shared with her to view; the second is refused.
    const term = uniq('bulkx').replace(' ', '')
    await api('e2e_ana').upload(node('ana_c').id, `${term}-mine.md`, '# mine\n')
    await owner().upload(node('for_ana').id, `${term}-theirs.md`, '# theirs\n')
    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('c'))
    await expect(row(ana, `${term}-mine.md`)).toBeVisible()
    await ana.getByRole('searchbox', { name: 'Search files and folders' }).fill(term)
    await ana.getByRole('button', { name: 'Everywhere' }).click()
    await expect(rows(ana)).toHaveCount(2)
    await ana.getByRole('checkbox', { name: 'Select all' }).check()
    await ana.getByRole('toolbar', { name: 'Selected items' }).getByRole('button', { name: 'Delete' }).click()
    await expect(ana.getByText(/1 moved to trash\. 1 refused/)).toBeVisible()
  })

  test('F2.13 search runs from the folder down, widens to every drive, highlights and shows each location; / focuses it', async ({ page }) => {
    const term = uniq('herox').replace(' ', '')
    const deep = await owner().folder(node('hero_folder').id, uniq('Deeper'))
    await owner().upload(deep.id, `${term}-share.md`, '# s\n')
    await owner().upload(ownerC(), `${term}-mine.md`, '# c\n')
    await openFolder(page, diskUrl(`d/${share('Marketing').slug}`), 'Marketing')
    await page.locator('body').press('/')
    const box = page.getByRole('searchbox', { name: 'Search files and folders' })
    await expect(box).toBeFocused()
    await box.fill(term)
    await expect(row(page, `${term}-share.md`)).toBeVisible()
    await expect(row(page, `${term}-share.md`)).toContainText('D:\\Marketing\\Launch 2026\\Assets\\Hero')
    await expect(row(page, `${term}-share.md`).locator('mark')).toHaveText(term)
    await expect(row(page, `${term}-mine.md`)).toHaveCount(0)
    await page.getByRole('button', { name: 'Everywhere' }).click()
    await expect(row(page, `${term}-mine.md`)).toBeVisible()

    // Opening a folder from the results lands in it with the search cleared.
    await box.fill(deep.name)
    await row(page, deep.name).getByRole('button', { name: deep.name }).click()
    await expect(page.getByRole('heading', { level: 1, name: deep.name })).toBeVisible()
    await expect(page.getByRole('searchbox', { name: 'Search files and folders' })).toHaveValue('')
    await expect(crumbs(page)).toContainText('Hero')
  })

  test('F2.14 search by name across everything I can see, and never what I cannot open', async ({ as }) => {
    const ana = await as('e2e_ana')
    await ana.goto(diskUrl('c'))
    await expect(row(ana, 'ana-notes.md')).toBeVisible()
    const box = ana.getByRole('searchbox', { name: 'Search files and folders' })
    await box.fill('budget')
    await ana.getByRole('button', { name: 'Everywhere' }).click()
    await expect(row(ana, 'budget.xlsx')).toHaveCount(1) // Marketing\Samples, not Finance
    await expect(row(ana, 'budget.xlsx')).toContainText('Samples')
    const r = await api('e2e_ana').get('/search?q=budget&scope=all')
    expect(r.results.map((n) => n.id)).not.toContain(node('finance_sheet').id)
    await box.fill('welcome')
    await expect(row(ana, 'welcome.md')).toBeVisible() // shared with her by name
  })

  test('F2 a viewer\'s drop is refused with a message, and nothing is uploaded', async ({ as }) => {
    const vic = await as('e2e_vic')
    await openFolder(vic, idUrl(node('samples')), 'Samples')
    await dropFiles(vic, [{ name: 'viewer.txt', type: 'text/plain', body: 'no' }])
    await expect(toast(vic)).toContainText('You can view this folder but not upload to it')
    await expect(row(vic, 'viewer.txt')).toHaveCount(0)
  })
})
