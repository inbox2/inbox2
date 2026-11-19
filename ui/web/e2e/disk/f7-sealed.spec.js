import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { test, expect, newItem, newSealedShareMenu, row, rows, sample, seed, slideOver, tile, uniq, uploads, user } from './support.js'
import { SEAL, surl, sapi, unlockPrompt, unlockIn, newSealedShare, uploadHere, addHolder, shortIdOf, openShare, appImport, ORG_ID } from './sealedSupport.js'
import { API, RAILS, railsEnv } from './env.js'

/* F7. Sealed, end to end: the real browser crypto (lib/disk/crypto.js, sealed.js,
 * the Disk service worker) against the real API and real Garage, in org e2e-seal,
 * whose people got identity keys from the real client in global-setup.js. Nothing
 * here fakes ciphertext. */

const openIn = openShare

const PREVIEWS = [
  ['report.pdf', (p) => p.locator('canvas')],
  ['photo.jpg', (p) => p.getByRole('img', { name: 'photo.jpg' })],
  ['diagram.svg', (p) => p.getByRole('img', { name: 'diagram.svg' })],
  ['clip.mp4', (p) => p.locator('video')],
  ['voice.m4a', (p) => p.locator('canvas[aria-label^="Waveform"][data-ready="true"]')], // the player's waveform, decoded through the service worker
  ['notes.md', (p) => p.frameLocator('iframe').getByRole('heading', { name: 'Release notes' })],
  ['app.js', (p) => p.locator('.cm-content')],
  ['data.csv', (p) => p.locator('table')],
  ['plan.docx', (p) => p.locator('iframe')],
  ['budget.xlsx', (p) => p.getByRole('tab').first()],
  ['deck.pptx', (p) => p.locator('iframe')],
  ['bundle.zip', (p) => p.getByRole('button', { name: 'notes.md' })],
]

test.describe('F7 sealed', () => {
  test.use({ person: 'e2e_sol' })

  test('F7.1 F7.8 a sealed share and a sealed C:\\ folder are created after the lost-keys warning; uploads list with decrypted names', async ({ page }) => {
    const name = uniq('Vault')
    await page.goto(surl('d'))
    await newSealedShareMenu(page)
    const dlg = page.getByRole('dialog')
    await unlockPrompt(page)
    await dlg.getByLabel('Name').fill(name)
    const create = dlg.getByRole('button', { name: 'Create sealed share' })
    await expect(create).toBeDisabled() // until the warning is acknowledged
    await expect(dlg).toContainText('I lose these files')
    await dlg.getByText(/If I lose my password and recovery phrase/).click()
    await create.click()
    await expect(page.locator('main h1')).toHaveText(name)
    await expect(page.getByRole('navigation', { name: 'Path' })).toContainText(name)
    await uploadHere(page, [sample('notes.md')])
    await expect(row(page, 'notes.md')).toContainText('sealed')
    // The API holds no name for it.
    const share = (await sapi('e2e_sol').get('/shares')).shares.find((s) => s.name === name)
    expect(share.sealed).toBe(true)
    const { nodes } = await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)
    expect(nodes[0].name).toBeNull()
    expect(nodes[0].metadata_ciphertext).toBeTruthy()
    // A sealed share is never open to the org.
    expect((await sapi('e2e_sol').call('PATCH', `/shares/${share.id}`, { openness: 'org', org_role: 'view' })).status).toBeGreaterThanOrEqual(400)
    // Search finds sealed names in the browser; the server's search cannot see them.
    await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('notes')
    await expect(row(page, 'notes.md')).toBeVisible()
    expect((await sapi('e2e_sol').get('/search?q=notes&scope=all')).results.filter((r) => r.sealed)).toEqual([])
    await page.getByRole('searchbox', { name: 'Search files and folders' }).fill('')

    // A sealed folder on C:\ (the warning was acknowledged in this browser).
    const folder = uniq('Private')
    await page.getByRole('link', { name: /My disk/ }).click()
    await newItem(page, 'Sealed folder')
    await page.getByRole('dialog').getByLabel('Name').fill(folder)
    await page.getByRole('dialog').getByRole('button', { name: 'Create sealed folder' }).click()
    await expect(page.locator('main h1')).toHaveText(folder) // opened, its name decrypted here
    await expect(page.getByText('In C:\\, sealed')).toBeVisible()
    await page.getByRole('link', { name: /My disk/ }).click()
    await expect(row(page, folder)).toContainText('sealed')
  })

  test('F7.7 a fresh session gets the unlock prompt, and the folder lists after unlocking', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Locked'))
    await uploadHere(page, [sample('data.csv')])
    const fresh = await as('e2e_sol')
    await fresh.goto(surl(`d/${share.slug}`))
    await expect(fresh.getByRole('status').filter({ hasText: 'Unlock your key to see names' })).toBeVisible()
    await expect(row(fresh, 'data.csv')).toHaveCount(0)
    await unlockPrompt(fresh)
    await expect(row(fresh, 'data.csv')).toBeVisible()
  })

  test('F7.2 every preview type works on a sealed file, and download and zip give the plaintext', async ({ page }) => {
    test.setTimeout(240_000)
    const share = await newSealedShare(page, uniq('Previews'))
    await uploadHere(page, PREVIEWS.map(([f]) => sample(f)))
    for (const [name, ready] of PREVIEWS) {
      await row(page, name).getByRole('button', { name: new RegExp(`^${name.replace('.', '\\.')}`) }).click()
      const panel = slideOver(page)
      await expect(ready(panel), name).toBeVisible({ timeout: 30_000 })
      await page.keyboard.press('Escape')
    }
    // Download one file: the browser decrypts it.
    const d = page.waitForEvent('download')
    await row(page, 'data.csv').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Download', exact: true }).click()
    expect(fs.readFileSync(await (await d).path())).toEqual(fs.readFileSync(sample('data.csv')))
    // A folder zip holds the decrypted files.
    await page.keyboard.press('Escape') // the right-click selected data.csv
    await newItem(page, 'Folder')
    const field = page.getByRole('textbox', { name: /^Rename/ })
    await field.fill('Zipped')
    await field.press('Enter')
    await row(page, 'Zipped').getByRole('button', { name: /^Zipped/ }).click()
    await uploadHere(page, [sample('notes.md')])
    // Two rows carry the name: the previews step uploaded a notes.md too.
    await expect(uploads(page).locator('li', { hasText: 'notes.md' }).filter({ hasText: 'Done' })).toHaveCount(2, { timeout: 30_000 }) // the row shows from the reservation; the zip needs the stored version
    await page.getByRole('navigation', { name: 'Path' }).getByRole('button', { name: share.name }).click()
    await page.evaluate(() => { delete window.showSaveFilePicker })
    const z = page.waitForEvent('download')
    await row(page, 'Zipped').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Download as zip' }).click()
    const zipPath = await (await z).path()
    expect(execFileSync('unzip', ['-l', zipPath], { encoding: 'utf8' })).toContain('Zipped/notes.md')
    expect(execFileSync('unzip', ['-p', zipPath, 'Zipped/notes.md'], { encoding: 'utf8' })).toBe(fs.readFileSync(sample('notes.md'), 'utf8'))
  })

  test('F7.3 a 38 MB sealed video seeks to the middle and plays through the service worker without fetching it all', async ({ page }) => {
    test.setTimeout(240_000)
    const big = sample('long.mp4')
    const size = fs.statSync(big).size
    await newSealedShare(page, uniq('Media'))
    await uploadHere(page, [big])
    let fetched = 0
    page.on('requestfinished', async (r) => {
      if (!r.url().includes(':4900/')) return
      const len = Number((await r.response())?.headers()['content-length'] || 0)
      fetched += len
    })
    await row(page, 'long.mp4').getByRole('button', { name: /^long\.mp4/ }).click()
    const video = slideOver(page).locator('video')
    await expect(video).toBeVisible({ timeout: 30_000 })
    expect(await video.getAttribute('src')).toMatch(/^\/disk\/sealed\//)
    await expect.poll(() => video.evaluate((v) => v.duration), { timeout: 30_000 }).toBeGreaterThan(50)
    fetched = 0
    await video.evaluate((v) => { v.muted = true; v.currentTime = 30; return v.play() })
    await expect.poll(() => video.evaluate((v) => v.currentTime), { timeout: 30_000 }).toBeGreaterThan(31)
    expect(fetched).toBeLessThan(size / 2)
  })

  test('F7.3 a 500 MB sealed video seeks to the middle and plays (E2E_DISK_LARGE)', async ({ page }) => {
    test.skip(!process.env.E2E_DISK_LARGE, 'set E2E_DISK_LARGE=1 to run the 500 MB case')
    test.setTimeout(900_000)
    const big = sample('big500.mp4')
    const size = fs.statSync(big).size
    await newSealedShare(page, uniq('Big media'))
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(big)
    await expect(row(page, 'big500.mp4')).toBeVisible({ timeout: 600_000 })
    let fetched = 0
    page.on('requestfinished', async (r) => { if (r.url().includes(':4900/')) fetched += Number((await r.response())?.headers()['content-length'] || 0) })
    await row(page, 'big500.mp4').getByRole('button', { name: /^big500\.mp4/ }).click()
    const video = slideOver(page).locator('video')
    await expect.poll(() => video.evaluate((v) => v.duration), { timeout: 60_000 }).toBeGreaterThan(70)
    fetched = 0
    await video.evaluate((v) => { v.muted = true; v.currentTime = v.duration / 2; return v.play() })
    await expect.poll(() => video.evaluate((v) => v.currentTime), { timeout: 60_000 }).toBeGreaterThan(41)
    expect(size).toBeGreaterThan(450 * 1024 * 1024)
    expect(fetched).toBeLessThan(size / 4)
  })

  test('F7.3 a tab that loaded on mail and switched to Disk is controlled by the worker', async ({ page }) => {
    await page.goto(`/${SEAL}/mail`)
    await page.getByRole('button', { name: 'Disk' }).click()
    await page.waitForURL('**/disk/c')
    await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller), { timeout: 15_000 }).toBe(true)
  })

  test('F7.4 a holder added later opens existing files at once', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Team'))
    await uploadHere(page, [sample('notes.md')])
    await addHolder(page, share.name, 'Sam Holder')
    const sam = await as('e2e_sam')
    await openIn(sam, share)
    await row(sam, 'notes.md').getByRole('button', { name: /^notes\.md/ }).click()
    await expect(slideOver(sam).frameLocator('iframe').getByRole('heading', { name: 'Release notes' })).toBeVisible()
  })

  test('F7.5 a sealed scope is shared whole: part of it offers "Move to a new sealed share"; an admin who is not a holder cannot open it', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Whole'))
    await newItem(page, 'Folder')
    const field = page.getByRole('textbox', { name: /^Rename/ })
    await field.fill('Part')
    await field.press('Enter')
    await row(page, 'Part').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Key holders...' }).click()
    await expect(page.getByRole('dialog')).toContainText('Key holders get the whole folder')
    await expect(page.getByRole('dialog').getByRole('button', { name: 'Move', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')
    // The API makes no access for a person on a node inside the scope.
    const part = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes[0]
    const r = await sapi('e2e_sol').call('PUT', `/nodes/${part.id}/grants/${user('e2e_sam').membership_id}`, { role: 'view' })
    expect(r.status).toBeGreaterThanOrEqual(400)
    // Sid is an admin with an identity key but not a holder: he sees the share, not its contents.
    const sid = await as('e2e_sid')
    await sid.goto(surl(`d/${share.slug}`))
    await unlockIn(sid)
    await expect(sid.getByRole('status').filter({ hasText: "you don't hold its key" })).toBeVisible()
    await expect(rows(sid)).toHaveCount(0)
    // ...but he can rename it (and delete it), as an admin of the org.
    const renamed = await sapi('e2e_sid').call('PATCH', `/shares/${share.id}`, { name: `${share.name} renamed` })
    expect(renamed.status).toBe(200)
    expect((await sapi('e2e_sid').call('GET', `/nodes/${part.id}/children`)).status).toBeGreaterThanOrEqual(400)
  })

  test('F7.6 removing a holder rotates the key; the dialog says earlier files stay readable to them', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Rotate'))
    await uploadHere(page, [sample('notes.md')])
    await addHolder(page, share.name, 'Sue Leaver')
    const sue = await as('e2e_sue')
    await openIn(sue, share)
    await expect(row(sue, 'notes.md')).toBeVisible()
    await page.goto(surl('d'))
    await unlockIn(page)
    await tile(page, share.name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Members' }).click()
    await page.getByRole('dialog').locator('li').filter({ hasText: 'Sue Leaver' }).getByRole('button', { name: 'Remove' }).click()
    const confirm = page.getByRole('dialog').last()
    await expect(confirm).toContainText('They can still open files they could open before')
    await confirm.getByRole('button', { name: 'Remove and renew the key' }).click()
    await expect.poll(async () => (await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)).scope.epoch, { timeout: 15_000 }).toBe(2)
    await expect(page.getByRole('dialog').getByRole('heading', { name: /^Key holders/ })).toBeVisible()
    await expect(page.getByRole('dialog').locator('li').filter({ hasText: 'Sue Leaver' })).toHaveCount(0)
    const { scope } = await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)
    expect(scope.epoch).toBe(2)
    await sue.reload()
    await unlockIn(sue)
    await expect(sue.getByRole('alert').or(sue.locator('main')).filter({ hasText: /not found|no key|hold no key/i }).first()).toBeVisible()
  })

  test('F7.9 a single sealed file link: with and without a password, the key leaves the address bar, no third-party requests, no name in the URL', async ({ page, browser }) => {
    await newSealedShare(page, uniq('Linked'))
    await uploadHere(page, [sample('report.pdf')])
    const make = async (password) => {
      await row(page, 'report.pdf').click({ button: 'right' })
      await page.getByRole('menuitem', { name: 'Public link...' }).click()
      const dlg = page.getByRole('dialog')
      if (password) await dlg.getByLabel('Password (optional)').fill(password)
      await dlg.getByRole('button', { name: 'Make link' }).click()
      const link = await dlg.getByRole('textbox', { name: 'Link' }).inputValue()
      await page.keyboard.press('Escape')
      return link
    }
    for (const password of [null, 'pass-phrase-1']) {
      const link = await make(password)
      const u = new URL(link)
      expect(u.hash.length).toBeGreaterThan(20)
      expect(u.pathname).toMatch(/^\/share\/[A-Za-z0-9]{22}$/) // no name in the address
      expect(link).not.toContain('report')
      const ctx = await browser.newContext()
      const v = await ctx.newPage()
      const secret = u.hash.slice(1)
      const scripts = new Set()
      const leaks = []
      v.on('request', (r) => {
        const host = new URL(r.url()).host
        // React Grab is the dev-only inspector (react-grab), never in a build.
        if (r.resourceType() === 'script' && !host.startsWith('localhost') && host !== 'www.react-grab.com') scripts.add(host)
        if (r.url().includes(secret) || JSON.stringify(r.headers()).includes(secret) || (r.postData() || '').includes(secret)) leaks.push(r.url())
      })
      await v.goto(u.pathname + u.hash)
      if (password) {
        await v.getByLabel('Password').fill(password)
        await v.getByRole('button', { name: 'Open' }).click()
      }
      await expect(v.locator('canvas').first()).toBeVisible({ timeout: 30_000 })
      await expect(v.getByRole('heading', { name: /report\.pdf/ })).toBeVisible()
      expect(v.url()).not.toContain('#')
      expect(await v.evaluate(() => location.hash)).toBe('')
      expect([...scripts], 'third-party scripts').toEqual([])
      expect(leaks, 'requests carrying the key').toEqual([])
      // The server's log of the visit holds no key material.
      expect(fs.readFileSync(path.join(API, 'log/development.log'), 'utf8').includes(secret)).toBe(false)
      await ctx.close()
    }
  })

  test('F7.9 a sealed folder offers no public link, and the API refuses one', async ({ page }) => {
    const share = await newSealedShare(page, uniq('NoFolderLinks'))
    await newItem(page, 'Folder')
    const field = page.getByRole('textbox', { name: /^Rename/ })
    await field.fill('Inner')
    await field.press('Enter')
    await row(page, 'Inner').click({ button: 'right' })
    await expect(page.getByRole('menu')).toBeVisible()
    await expect(page.getByRole('menuitem', { name: 'Public link...' })).toHaveCount(0)
    await page.keyboard.press('Escape')
    const inner = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes[0]
    expect((await sapi('e2e_sol').call('POST', `/nodes/${inner.id}/links`, {})).status).toBeGreaterThanOrEqual(400)
  })

  test('F7.10 a sealed page: two holders type live and converge', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Pages'))
    await addHolder(page, share.name, 'Sam Holder')
    await openIn(page, share)
    await newItem(page, 'Page')
    const ed = (p) => p.locator('article .ProseMirror')
    await expect(ed(page)).toBeVisible()
    const pageUrl = page.url()
    const sam = await as('e2e_sam')
    // Everything relayed over the page channel is ciphertext.
    const frames = []
    sam.on('websocket', (ws) => ws.on('framereceived', (f) => frames.push(String(f.payload))))
    await sam.goto(pageUrl)
    await unlockIn(sam)
    await expect(ed(sam)).toBeVisible()
    await ed(page).click()
    await page.keyboard.type('Sol types here. ')
    await expect(ed(sam)).toContainText('Sol types here.')
    await ed(sam).click()
    await sam.keyboard.press('End')
    await sam.keyboard.type('Sam too.')
    await expect(ed(page)).toContainText('Sam too.')
    // The server stores only ciphertext, and relayed only ciphertext.
    const nodeId = shortIdOf(pageUrl)
    const stored = await sapi('e2e_sol').get(`/pages/${nodeId}`)
    expect(JSON.stringify(stored)).not.toContain('Sol types here')
    expect(frames.length).toBeGreaterThan(0)
    expect(frames.join('\n')).not.toContain('Sol types here')
    // Export .md is made in the browser from the open editor: readable, with nothing plain fetched for it.
    const fetched = []
    page.on('response', async (r) => { if (r.url().includes('/api/')) fetched.push(await r.text().catch(() => '')) })
    const d = page.waitForEvent('download')
    await page.getByRole('button', { name: 'Export .md' }).click()
    expect(fs.readFileSync(await (await d).path(), 'utf8')).toContain('Sol types here. Sam too.')
    expect(fetched.join('\n')).not.toContain('Sol types here')
    // A server-side org export lists the sealed page as encrypted and leaves it out.
    const { export: ex } = await sapi('e2e_sol').get('/admin/export')
    expect(ex.note || JSON.stringify(ex)).toMatch(/Sealed files and pages are listed as encrypted and not included/)
    const entry = ex.entries.find((e) => (e.id || e.node_id || '').endsWith(nodeId))
    if (entry) expect(entry.markdown ?? null).toBeNull()

    // A folder zip and the org export, both built in this browser, which holds the key, carry the page as markdown.
    await page.getByRole('button', { name: 'Done' }).click()
    await expect(row(page, 'Untitled')).toBeVisible()
    await page.evaluate(() => { delete window.showSaveFilePicker }) // the Blob path; a headless browser cannot answer the picker
    await row(page, 'Untitled').locator('input[type="checkbox"]').check()
    const z = page.waitForEvent('download')
    await page.getByRole('button', { name: 'Download', exact: true }).click()
    const zipPath = await (await z).path()
    expect(execFileSync('unzip', ['-p', zipPath], { encoding: 'utf8' })).toContain('Sol types here. Sam too.')
    await page.goto('/console/disk')
    await unlockIn(page)
    await page.evaluate(() => { delete window.showSaveFilePicker })
    const x = page.waitForEvent('download', { timeout: 90_000 })
    await page.getByRole('button', { name: 'Start export' }).click()
    const exportPath = await (await x).path()
    const listing = execFileSync('unzip', ['-l', exportPath], { encoding: 'utf8' })
    expect(listing).toContain('(sealed).md')
    expect(execFileSync('unzip', ['-p', exportPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })).toContain('Sol types here. Sam too.')
  })
  test('F7.6 when a key holder leaves the org, writes stop and a banner asks a manager to renew the key; renewing clears it', async ({ page }) => {
    const share = await newSealedShare(page, uniq('Freeze'))
    await addHolder(page, share.name, 'Lou Leaving')
    // Lou is disabled in the org (offboarding): her grants go, the scope must rotate before any write.
    const off = await fetch(`${RAILS}/api/v1/admin/users/${user('e2e_lou').id}/status`, {
      method: 'PATCH', headers: { Authorization: `Bearer ${user('e2e_sol').token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'disabled', scope: 'membership', org_id: seed.orgs[SEAL].id }),
    })
    expect(off.status).toBe(200)
    await openShare(page, share)
    const banner = page.getByRole('status').filter({ hasText: 'A key holder left' })
    await expect(banner).toBeVisible()
    await newItem(page, 'Folder')
    await expect(page.getByText(/renew its key|key holder left/i).last()).toBeVisible()
    expect((await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes).toEqual([])
    // The banner leads to the key holders, where renewing is confirmed.
    await banner.getByRole('button', { name: 'Renew the key' }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Renew the key' }).click()
    await page.getByRole('dialog').last().getByRole('button', { name: 'Renew', exact: true }).click()
    await expect(banner).toHaveCount(0)
    expect((await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)).scope.rotation_due).toBe(false)
    await page.keyboard.press('Escape')
    await uploadHere(page, [sample('data.csv')])
  })

  test('F7.9 while a departed key holder awaits a renewed key, a sealed file link is refused with the renew-key message', async ({ page }) => {
    const share = await newSealedShare(page, uniq('Frozen link'))
    await addHolder(page, share.name, 'Lex Leaving')
    await openShare(page, share)
    await uploadHere(page, [sample('report.pdf')])
    const off = await fetch(`${RAILS}/api/v1/admin/users/${user('e2e_lex').id}/status`, {
      method: 'PATCH', headers: { Authorization: `Bearer ${user('e2e_sol').token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ status: 'disabled', scope: 'membership', org_id: seed.orgs[SEAL].id }),
    })
    expect(off.status).toBe(200)
    expect((await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)).scope.rotation_due).toBe(true)
    await openShare(page, share)
    await row(page, 'report.pdf').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Public link...' }).click()
    const dlg = page.getByRole('dialog')
    await dlg.getByRole('button', { name: 'Make link' }).click()
    await expect(dlg.getByRole('alert')).toHaveText('A key holder left. Renew the key in Key holders, then make the link.')
    await expect(dlg.getByRole('textbox', { name: 'Link' })).toHaveCount(0)
    const file = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes[0]
    expect((await sapi('e2e_sol').get(`/nodes/${file.id}/links`)).links).toEqual([])
  })

  test('F7.11 moving a file into a sealed share and another out of one leaves no plaintext behind in the bucket', async ({ page }) => {
    test.setTimeout(180_000)
    const tag = Date.now().toString(36)
    const inMark = `CROSSINMARK${tag}`
    const c = (await sapi('e2e_sol').get('/')).c_drive.id
    const plain = await sapi('e2e_sol').upload(c, `into-${tag}.md`, `# ${inMark} v1\n`)
    await sapi('e2e_sol').upload(c, `into-${tag}.md`, `# ${inMark} v2\n`, { node_id: plain.id, parent_id: undefined })
    const share = await newSealedShare(page, uniq('Cross'))
    // In: C:\ to the sealed share.
    await page.goto(surl('c'))
    await unlockIn(page)
    await row(page, `into-${tag}.md`).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Move to...' }).click()
    await page.getByRole('dialog').getByRole('button', { name: new RegExp(`^${share.name}`) }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Move here' }).click()
    const cross = page.getByRole('dialog').filter({ hasText: 'Move and seal?' })
    await expect(cross).toContainText('deletes the originals')
    await cross.getByRole('button', { name: 'Move' }).click()
    await expect(cross.getByRole('status')).toContainText('1 of 1 done', { timeout: 60_000 })
    await cross.getByRole('button', { name: 'Close' }).click()
    await expect(row(page, `into-${tag}.md`)).toHaveCount(0)
    expect(bucketScan([inMark]).hits[inMark], 'plaintext of the moved file or its old version').toEqual([])
    // Out: the sealed share to C:\.
    await openShare(page, share)
    await expect(row(page, `into-${tag}.md`)).toBeVisible()
    await row(page, `into-${tag}.md`).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Move to...' }).click()
    await page.getByRole('dialog').getByRole('button', { name: /^C:\\/ }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Move here' }).click()
    const out = page.getByRole('dialog').filter({ hasText: 'Move and unseal?' })
    await expect(out).toContainText('inbox2 can read them')
    await out.getByRole('button', { name: 'Move' }).click()
    await expect(out.getByRole('status')).toContainText('1 of 1 done', { timeout: 60_000 })
    await out.getByRole('button', { name: 'Close' }).click()
    expect((await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes).toEqual([])
    const back = (await sapi('e2e_sol').get(`/nodes/${c}/children`)).nodes.find((n) => n.name === `into-${tag}.md`)
    expect(back.sealed).toBe(false)
    const { download } = await sapi('e2e_sol').get(`/nodes/${back.id}/download`)
    expect(await (await fetch(download.url)).text()).toBe(`# ${inMark} v2\n`)
  })

  test('F7.1 Seal on a C:\\ folder\'s menu seals it in place: contents moved into a sealed folder of the same name, no plaintext, links revoked, the original gone', async ({ page }) => {
    test.setTimeout(180_000)
    const tag = Date.now().toString(36)
    const mark = `SEALINPLACE${tag}`
    const c = (await sapi('e2e_sol').get('/')).c_drive.id
    const name = `To seal ${tag}`
    const folder = await sapi('e2e_sol').folder(c, name)
    const top = await sapi('e2e_sol').upload(folder.id, 'top.md', `# ${mark} top\n`)
    await sapi('e2e_sol').upload(folder.id, 'top.md', `# ${mark} top v2\n`, { node_id: top.id, parent_id: undefined })
    const sub = await sapi('e2e_sol').folder(folder.id, 'Inner')
    await sapi('e2e_sol').upload(sub.id, 'deep.md', `# ${mark} deep\n`)
    const { link } = await sapi('e2e_sol').post(`/nodes/${top.id}/links`, {})

    await page.goto(surl('c'))
    await unlockIn(page)
    await row(page, name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Seal...' }).click()
    const ask = page.getByRole('dialog').filter({ hasText: `Seal "${name}"?` })
    await expect(ask).toContainText("Older versions don't carry over")
    await expect(ask).toContainText('Public links stop working')
    const ack = ask.getByText(/If I lose my password and recovery phrase/)
    if (await ack.isVisible().catch(() => false)) await ack.click()
    await ask.getByRole('button', { name: 'Seal folder' }).click()
    const run = page.getByRole('dialog').filter({ hasText: `Sealing "${name}"` })
    await expect(run.getByRole('status')).toContainText('2 of 2 done', { timeout: 90_000 })
    await run.getByRole('button', { name: 'Close' }).click()

    // One folder of that name is left, and it is sealed; inside, the files open with their names.
    await expect(row(page, name)).toHaveCount(1)
    await expect(row(page, name)).toContainText('sealed')
    const left = (await sapi('e2e_sol').get(`/nodes/${c}/children`)).nodes
    expect(left.filter((n) => n.name === name)).toEqual([])
    expect((await sapi('e2e_sol').call('GET', `/nodes/${folder.id}`)).status).toBe(404)
    await row(page, name).getByRole('button', { name: new RegExp(`^${name}`) }).click()
    await expect(row(page, 'top.md')).toBeVisible()
    await expect(row(page, 'Inner')).toBeVisible()
    // Only the current version was carried over, the link is gone, and no plaintext is left in the bucket.
    expect((await fetch(`${RAILS}/api/v1/disk/links/${link.token}`)).status).toBe(404)
    expect(bucketScan([mark]).hits[mark], 'plaintext of the sealed files or their old versions').toEqual([])
  })

  test('F7.1 Seal is refused before anything is made when the folder holds a sealed folder', async ({ page }) => {
    const c = (await sapi('e2e_sol').get('/')).c_drive.id
    const name = uniq('Holds sealed')
    await sapi('e2e_sol').folder(c, name)
    await page.goto(surl('c'))
    await unlockIn(page)
    // A sealed folder inside it, made through the real client.
    await appImport(page)
    const folderId = (await sapi('e2e_sol').get(`/nodes/${c}/children`)).nodes.find((n) => n.name === name).id
    await page.evaluate(async ({ org, parent }) => {
      const lib = await window.__appImport('/src/lib/disk/sealed.js')
      const { identityKeys } = await window.__appImport('/src/lib/e2eeStore.js')
      await lib.createSealedRoot({ orgId: org, parentId: parent, name: 'Vault inside', identity: identityKeys() })
    }, { org: ORG_ID(), parent: folderId })
    await page.reload()
    const sealedAtTop = async () => (await sapi('e2e_sol').get(`/nodes/${c}/children`)).nodes.filter((n) => n.sealed).length
    const before = await sealedAtTop()
    await row(page, name).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Seal...' }).click()
    await expect(page.getByRole('status').filter({ hasText: 'This folder has a sealed folder inside' })).toBeVisible()
    await expect(page.getByRole('dialog')).toHaveCount(0)
    expect(await sealedAtTop()).toBe(before) // no sealed sibling was made
    expect((await sapi('e2e_sol').get(`/nodes/${folderId}/children`)).nodes).toHaveLength(1)
  })
})

const bucketScan = (markers) => JSON.parse(execFileSync('bin/rails', ['e2e:disk:bucket_scan'], {
  cwd: API, env: { ...railsEnv(), MARKERS: markers.join(',') }, encoding: 'utf8',
}).trim().split('\n').at(-1))
