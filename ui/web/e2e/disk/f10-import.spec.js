import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import { test, expect, api, uniq } from './support.js'
import { API, BASE, FAKE, RAILS, railsEnv } from './env.js'
import { newSealedShare } from './sealedSupport.js'

/* F10. Importers, run for real against local fakes of Google Drive, Microsoft 365
 * and Dropbox (fake-providers.mjs: consent, tokens and the file APIs the adapters
 * call, over one fixed tree; the e2e Rails points the importers there through
 * DISK_IMPORT_<P>_<NAME>_URL). The import job runs the way the app runs jobs in
 * development: in the Rails process (Active Job's async adapter). Org e2e-imp:
 * Ivy imports, Cal is matched at the source by the email he signs in with, Stan
 * (at the source) is no member, Pat is an outside collaborator. */

const ORG = 'e2e-imp'
const SOURCES = [
  { p: 'google', label: 'Google', folder: 'Google Drive', team: 'Google Team', converts: ['Budget.xlsx', 'Deck.pptx'], page: true, none: /A Google form has no file to export/, link: true },
  { p: 'microsoft', label: 'Microsoft 365', folder: 'OneDrive', team: 'SharePoint Team', converts: [], page: false, none: /A OneNote notebook has no file to download/, link: true },
  { p: 'dropbox', label: 'Dropbox', folder: 'Dropbox', team: 'Dropbox Team', converts: ['Budget.xlsx'], page: true, none: /Dropbox offers neither a download nor an export/, link: false },
]

const ctl = async (p, body = {}) => (await fetch(`${FAKE}/_ctl/${p}`, { method: 'POST', body: JSON.stringify(body) })).json()
const rails = (task, env) => execFileSync('bin/rails', [task], { cwd: API, env: { ...railsEnv(), ...env } }).toString().trim()
const ivy = () => api('e2e_ivy')
const kids = async (u, id) => (await api(u).get(`/nodes/${id}/children`)).nodes
const child = async (u, id, name) => (await kids(u, id)).find((n) => n.name === name)
const text = async (u, id) => (await fetch((await api(u).get(`/nodes/${id}/download`)).download.url)).text()
const cDrive = async (u) => (await api(u).get('/')).c_drive.id

// The import wizard (a dialog, since ea0e3c60), open on one source.
const card = (page) => page.getByRole('dialog')
// The newest import of a space (the list is newest first); every import row has a Report button.
const importRow = (page, name) => page.locator('li').filter({ has: page.getByRole('button', { name: 'Report' }) }).filter({ has: page.getByText(name, { exact: true }) }).first()
const tick = (page, s, name) => card(page).getByRole('checkbox', { name: new RegExp(`^${name} (\\(|Your|This )`) }).check()
async function openImport(page) {
  await page.goto('/disk/import')
  await expect(page.getByRole('heading', { level: 1, name: 'Import' })).toBeVisible()
}
const pickSource = async (page, s) => {
  await card(page).getByRole('button', { name: new RegExp(`^${s.label}`) }).click()
  await expect(card(page).getByRole('heading', { name: s.label })).toBeVisible()
}
async function openWizard(page, s) {
  await page.getByRole('button', { name: 'Import files' }).click()
  await pickSource(page, s)
}
// Connect goes to the fake's consent, which grants and sends the browser back through the API's callback;
// the callback reopens the wizard on this source.
async function connect(page, s, button) {
  await card(page).getByRole('button', { name: button, exact: true }).click()
}
async function chooseTarget(page, s, folderName) {
  await card(page).getByRole('button', { name: 'Choose a folder...' }).click()
  const dlg = page.getByRole('dialog')
  await dlg.getByRole('button', { name: /^C:\\/ }).click()
  await dlg.getByRole('button', { name: new RegExp(`^${folderName}`) }).click()
  await dlg.getByRole('button', { name: 'Import here' }).click()
  await expect(dlg.getByRole('button', { name: 'Import here' })).toHaveCount(0) // back in the wizard
}
async function openReport(page, name) {
  await importRow(page, name).getByRole('button', { name: 'Report' }).click()
  const dlg = page.getByRole('dialog')
  await expect(dlg.getByRole('heading', { name: `Import report: ${name}` })).toBeVisible()
  return dlg
}

for (const s of SOURCES) {
  test.describe.serial(`F10 ${s.label}`, () => {
    test.use({ person: 'e2e_ivy' })
    let target // Ivy's chosen folder for her own drive
    let landed // the folder named for the source, inside it

    test(`F10.1 ${s.p}: Ivy connects read-only for herself and for the organization; the spaces are listed`, async ({ page }) => {
      await ctl(s.p, { reset: true })
      await openImport(page)
      await page.getByRole('button', { name: 'Import files' }).click()
      await expect(card(page).getByText('Imported files arrive unsealed.')).toBeVisible()
      await pickSource(page, s)
      await connect(page, s, `Connect ${s.label}`)
      await expect(card(page)).toContainText('Connected as ivy@imp.e2e.test')
      await connect(page, s, 'Connect for the organization')
      const c = card(page)
      await expect(c.getByRole('checkbox', { name: new RegExp(`^${s.team}`) })).toBeVisible()
      await expect(c.getByRole('checkbox', { name: /^Cal Colleague \(cal@imp\.e2e\.test\)/ })).toBeVisible()
      await expect(c.locator('label').filter({ hasText: 'Stan Stranger' })).toContainText('No member uses this address, so the import skips it.')
      // What was asked for at the source: read-only scopes only.
      const asked = (await ctl(s.p)).calls.filter((x) => x.authorize).map((x) => x.authorize)
      expect(asked).toHaveLength(2)
      for (const a of asked) {
        expect(a.client_id).toBe(`e2e-${s.p}-client`)
        expect(a.redirect_uri).toBe(`http://localhost:4620/api/v1/disk/imports/${s.p}/callback`)
        expect(a.scope).not.toMatch(/drive(?![.\w]*readonly)\b|ReadWrite|files\.content\.write|files\.metadata\.write/)
      }
      if (s.p === 'google') expect(asked[0].scope).toContain('drive.readonly')
      if (s.p === 'microsoft') expect(asked[0].scope).toContain('Files.Read')
      if (s.p === 'dropbox') expect(asked[0].scope).toContain('files.content.read')
    })

    test(`F10.1 ${s.p}: her drive arrives in the chosen folder with live progress, a throttle wait, conversions, hash checks and sharing`, async ({ page, as }) => {
      test.setTimeout(120_000)
      target = await ivy().folder(await cDrive('e2e_ivy'), uniq(`Into ${s.p}`))
      await ctl(s.p, { throttleOnce: true, holdAfter: 2 })
      await openImport(page)
      await openWizard(page, s)
      await tick(page, s, s.folder)
      await chooseTarget(page, s, target.name)
      await expect(card(page)).toContainText(`C:\\...\\${s.folder}`)
      await card(page).getByRole('button', { name: 'Start import' }).click()
      const row = importRow(page, s.folder)
      // The source asked for a wait (429, Retry-After 6): the import says so and waits.
      await expect(row).toContainText('Waiting for the source until', { timeout: 10_000 })
      // Two files through, the rest held at the source: live progress, and it goes on with the tab closed.
      await expect(row).toContainText(/Importing: 2 files, \d+ folders?/, { timeout: 20_000 })
      await page.close()
      const again = await as('e2e_ivy')
      await openImport(again)
      await expect(importRow(again, s.folder)).toContainText(/Importing: 2 files/)
      await ctl(s.p, { release: true })
      await expect(importRow(again, s.folder)).toContainText(/Done: \d+ files/, { timeout: 30_000 })

      // The structure under a folder named for the source.
      landed = await child('e2e_ivy', target.id, s.folder)
      expect(landed).toBeTruthy()
      const top = await kids('e2e_ivy', landed.id)
      const names = top.map((n) => n.name).sort()
      expect(names).toEqual(expect.arrayContaining(['Projects', 'old-name.txt', 'doomed.txt', ...s.converts, ...(s.page ? ['Roadmap'] : [])]))
      expect(names).not.toContain('corrupt.bin') // never matched its hash: not stored
      expect(names.join()).not.toMatch(/notebook/i) // no content: reported, not stored
      const projects = top.find((n) => n.name === 'Projects')
      const inProjects = await kids('e2e_ivy', projects.id)
      const specs = inProjects.find((n) => n.name === 'Specs')
      expect(await text('e2e_ivy', (await child('e2e_ivy', specs.id, 'spec.txt')).id)).toBe('spec v1\n')
      // Plan.txt and plan.txt differ only in case: both arrive, one renamed.
      const plans = inProjects.filter((n) => /^plan/i.test(n.name)).map((n) => n.name).sort()
      expect(plans).toHaveLength(2)
      expect(plans).toContain('Plan.txt')
      // The corrupt file was fetched twice (retried) before it was given up.
      const calls = (await ctl(s.p)).calls
      expect(calls.filter((x) => x.download === 'x-corrupt')).toHaveLength(2)
      if (s.p === 'microsoft') {
        // Graph paging followed (nextLink), and every file came through its pre-authenticated
        // download address (allowed for the override origin), with no token sent there.
        expect(calls.some((x) => x.call?.includes('/root/delta?token=page2'))).toBe(true)
        const dl = calls.filter((x) => x.download)
        expect(dl.length).toBeGreaterThan(4)
        expect(dl.every((x) => x.auth === null)).toBe(true)
      }
      // Shared with Cal at the source: shared with him here at the matching role.
      const { grants } = await ivy().get(`/nodes/${projects.id}/grants`)
      expect(grants.map((g) => [g.membership.name, g.role])).toContainEqual(['Cal Colleague', 'edit'])
      if (s.page) {
        const roadmap = top.find((n) => n.name === 'Roadmap')
        expect(roadmap.kind).toBe('page')
        await again.goto(`/disk/shared/Roadmap-${roadmap.id.slice(-21)}`)
        await expect(again.locator('.ProseMirror h2')).toHaveText('Next', { timeout: 20_000 })
        await expect(again.locator('.ProseMirror li').first()).toHaveText('Ship the importer')
        await openImport(again)
      }

      // The report: conversions not hash-verified, the hash failure, the no-content item, the rename, sharing not carried over.
      const dlg = await openReport(again, s.folder)
      if (s.page) await expect(dlg).toContainText(`converted ${s.converts.length + 1}`)
      // The report names the source's item (Budget), Disk holds the export (Budget.xlsx).
      for (const name of s.converts) await expect(dlg.locator('li').filter({ hasText: name.replace(/\.\w+$/, '') })).toContainText(/converted to (xlsx|pptx), not verified against the source/)
      if (s.page) await expect(dlg.locator('li').filter({ hasText: 'Roadmap' })).toContainText(/converted to md, not verified against the source/)
      await expect(dlg.locator('li').filter({ hasText: 'corrupt.bin' })).toContainText("failed: The download did not match the source's hash, twice")
      await expect(dlg.locator('li').filter({ hasText: /notebook/ })).toContainText(s.none)
      await expect(dlg).toContainText(/renamed from "(Plan|plan)\.txt" \(Another item in the folder has this name, ignoring case\), clashed with (Plan|plan)\.txt/)
      await expect(dlg.getByText('Unmatched people')).toBeVisible()
      await expect(dlg).toContainText('pat@outside.e2e.test')
      if (s.link) await expect(dlg.locator('li').filter({ hasText: 'Projects' })).toContainText('had a public link at the source (not copied)')
      const d = again.waitForEvent('download')
      await dlg.getByRole('button', { name: 'Download report' }).click()
      const json = JSON.parse(fs.readFileSync(await (await d).path(), 'utf8'))
      expect(json.entries.find((e) => e.name === 'corrupt.bin').status).toBe('failed')
      expect(json.unmatched_people.map((x) => x.email)).toContain('pat@outside.e2e.test')
    })

    test(`F10.2 ${s.p}: the team space becomes a share and Cal's drive lands in his C:\\, Stan's is skipped; at the quota it pauses, and resumes once space is freed`, async ({ page }) => {
      test.setTimeout(120_000)
      const filled = rails('e2e:disk:org_bytes', { ORG, DELTA: 'fill' })
      try {
        await openImport(page)
        await openWizard(page, s)
        for (const name of [s.team, 'Cal Colleague', 'Stan Stranger']) await tick(page, s, name)
        await card(page).getByRole('button', { name: 'Start import' }).click()
        await expect(importRow(page, 'Stan Stranger')).toContainText('No member of this organization uses stan@imp.e2e.test')
        await expect(importRow(page, s.team)).toContainText('Disk is full.', { timeout: 30_000 })
        // Cal's C:\ is his own (f2791d0c), outside this org's quota: his import is not paused.
        await expect(importRow(page, 'Cal Colleague')).toContainText(/Done: 1 file,/, { timeout: 30_000 })
      } finally {
        rails('e2e:disk:org_bytes', { ORG, DELTA: String(-Number(filled)) })
      }
      await importRow(page, s.team).getByRole('button', { name: 'Resume' }).click()
      await expect(importRow(page, s.team)).toContainText(/Done: 1 file,/, { timeout: 30_000 })
      // The share, its members carried over (Cal edits), its file.
      const share = (await ivy().get('/shares')).shares.find((x) => x.name === s.team)
      expect(share).toBeTruthy()
      expect(await text('e2e_ivy', (await child('e2e_ivy', share.root_node_id, 'team.txt')).id)).toBe('team\n')
      const { members } = await ivy().get(`/shares/${share.id}/members`)
      expect(members.map((m) => [m.name, m.role])).toContainEqual(['Cal Colleague', 'edit'])
      // Cal's own files, in his C:\ under a folder named for the source.
      const calFolder = await child('e2e_cal', await cDrive('e2e_cal'), s.folder)
      expect(await text('e2e_cal', (await child('e2e_cal', calFolder.id, 'cal.txt')).id)).toBe('cal\n')
      const dlg = await openReport(page, s.team)
      await expect(dlg).toContainText('pat@outside.e2e.test')
      if (s.p === 'microsoft') await expect(dlg.locator('li').filter({ hasText: 'Tasks' })).toContainText('skipped: A SharePoint list has no files')
    })

    test(`F10.6 ${s.p}: a revoked grant pauses with the cause; after connecting again the re-run brings only the changes`, async ({ page }) => {
      test.setTimeout(120_000)
      const before = (await kids('e2e_ivy', landed.id)).length
      await ctl(s.p, { pass: 2, revoked: true, goneOnce: s.p === 'microsoft' })
      await openImport(page)
      await openWizard(page, s)
      await tick(page, s, s.folder)
      await chooseTarget(page, s, target.name)
      await card(page).getByRole('button', { name: 'Start import' }).click()
      const row = importRow(page, s.folder)
      await expect(row).toContainText('The connection to the source stopped working. Connect again, then resume.', { timeout: 30_000 })
      // Connect again from the paused import, then resume.
      await row.getByRole('button', { name: 'Connect again' }).click()
      await page.waitForURL(/status=connected/, { timeout: 20_000 })
      await card(page).getByRole('button', { name: 'Cancel' }).click() // the callback reopened the wizard
      await importRow(page, s.folder).getByRole('button', { name: 'Resume' }).click()
      await expect(importRow(page, s.folder)).toContainText(/Done:/, { timeout: 30_000 })

      // Nothing doubled: same count of items, the rename followed, the deletion kept, the change a new version.
      const after = await kids('e2e_ivy', landed.id)
      expect(after).toHaveLength(before)
      const names = after.map((n) => n.name)
      expect(names).toContain('new-name.txt')
      expect(names).not.toContain('old-name.txt')
      expect(names).toContain('doomed.txt')
      const projects = after.find((n) => n.name === 'Projects')
      const notes = await child('e2e_ivy', projects.id, 'notes.txt')
      expect(await text('e2e_ivy', notes.id)).toBe('notes v2, changed at the source\n')
      expect((await ivy().get(`/nodes/${notes.id}/versions`)).versions).toHaveLength(2)
      const dlg = await openReport(page, s.folder)
      await expect(dlg.locator('li').filter({ hasText: 'doomed.txt' })).toContainText('deleted at the source (kept here)')
      await expect(dlg).toContainText(/updated 1/)
      if (s.p === 'microsoft') expect((await ctl(s.p)).calls.some((x) => x.call?.includes('token=resync'))).toBe(true)
    })

    test(`F10.6 ${s.p}: cancelling stops the import and keeps what came across`, async ({ page }) => {
      test.setTimeout(90_000)
      await ctl(s.p, { pass: 1, holdAfter: 1 })
      const into = await ivy().folder(await cDrive('e2e_ivy'), uniq(`Cancel ${s.p}`))
      await openImport(page)
      await openWizard(page, s)
      await tick(page, s, s.folder)
      await chooseTarget(page, s, into.name)
      await card(page).getByRole('button', { name: 'Start import' }).click()
      const row = importRow(page, s.folder)
      await expect(row).toContainText(/Importing: 1 file/, { timeout: 20_000 })
      await row.getByRole('button', { name: 'Cancel' }).click()
      await expect(row).toContainText('Cancelled')
      await ctl(s.p, { release: true })
      const kept = await child('e2e_ivy', into.id, s.folder)
      await expect.poll(async () => (await ivy().get('/imports')).imports[0].state).toBe('cancelled')
      expect((await kids('e2e_ivy', kept.id)).length).toBeGreaterThan(0)
    })

    if (s.p === 'dropbox') {
      test('F10.7 dropbox: the team data transport cap stops the import naming the cause; it resumes', async ({ page }) => {
        await ctl(s.p, { capOnce: true })
        const into = await ivy().folder(await cDrive('e2e_ivy'), uniq('Cap dropbox'))
        await openImport(page)
        await openWizard(page, s)
        await tick(page, s, s.folder)
        await chooseTarget(page, s, into.name)
        await card(page).getByRole('button', { name: 'Start import' }).click()
        const row = importRow(page, s.folder)
        await expect(row).toContainText('The source limits how much you can copy', { timeout: 30_000 })
        expect((await ivy().get('/imports')).imports[0].error).toMatch(/data transport API calls for the month/)
        await row.getByRole('button', { name: 'Resume' }).click()
        await expect(row).toContainText(/Done:/, { timeout: 30_000 })
      })
    }
  })
}

test.describe('F10.9 imports are unsealed', () => {
  test.use({ person: 'e2e_sol' })
  test('a sealed share cannot be the target: each source refuses it with the notice', async ({ page }) => {
    test.setTimeout(150_000)
    const sealed = await newSealedShare(page, uniq('Sealed target'))
    for (const s of SOURCES) {
      await page.goto('/disk/import?org=e2e-seal')
      await openWizard(page, s)
      await connect(page, s, `Connect ${s.label}`)
      await tick(page, s, s.folder)
      await card(page).getByRole('button', { name: 'Choose a folder...' }).click()
      const dlg = page.getByRole('dialog')
      await dlg.getByRole('button', { name: new RegExp(`^${sealed.name}`) }).click()
      await dlg.getByRole('button', { name: 'Import here' }).click()
      await card(page).getByRole('button', { name: 'Start import' }).click()
      await expect(page.getByRole('alert')).toHaveText("Imported files are not sealed, so they can't go into a sealed folder")
    }
    expect((await api('e2e_sol').get('/imports')).imports).toHaveLength(0)
  })
})

test.describe('F10 hardening (review round two)', () => {
  test.use({ person: 'e2e_ivy' })

  test('F10.1 the callback refuses a Google state on the Dropbox callback, and a state used once is refused when replayed', async () => {
    const { authorize_url: url } = await ivy().post('/imports/google/connect', { reach: 'member' })
    const state = new URL(url).searchParams.get('state')
    const back = (p) => fetch(`${RAILS}/api/v1/disk/imports/${p}/callback?state=${encodeURIComponent(state)}&code=code-${p}`, { redirect: 'manual' })
    const cross = await back('dropbox')
    expect(cross.status).toBe(302)
    expect(cross.headers.get('location')).toBe(`${BASE}/disk`) // no org, no status: the state names no Dropbox grant
    const first = await back('google')
    expect(first.headers.get('location')).toMatch(/\/disk\/import\?org=e2e-imp&source=google&status=connected$/)
    const replay = await back('google')
    expect(replay.status).toBe(302)
    expect(replay.headers.get('location')).toBe(`${BASE}/disk`)
  })

  test('F10.3 google: a Doc whose export is over the 5 MB page limit arrives as a .md file, and the report says why', async ({ page }) => {
    test.setTimeout(120_000)
    const s = SOURCES[0]
    await ctl('google', { pass: 1, bigDoc: true })
    try {
      const into = await ivy().folder(await cDrive('e2e_ivy'), uniq('Big doc'))
      await openImport(page)
      await openWizard(page, s)
      await tick(page, s, s.folder)
      await chooseTarget(page, s, into.name)
      await card(page).getByRole('button', { name: 'Start import' }).click()
      await expect(importRow(page, s.folder)).toContainText(/Done: \d+ files/, { timeout: 60_000 })
      const landed = await child('e2e_ivy', into.id, s.folder)
      const big = await child('e2e_ivy', landed.id, 'Big notes.md')
      expect(big).toMatchObject({ kind: 'file' })
      expect(big.size_bytes).toBeGreaterThan(5 * 1024 * 1024)
      expect((await kids('e2e_ivy', landed.id)).find((n) => n.name === 'Roadmap').kind).toBe('page') // the small Doc stays a page
      const dlg = await openReport(page, s.folder)
      await expect(dlg.locator('li').filter({ hasText: 'Big notes' })).toContainText('Over the 5 MB page limit, so it was imported as a file')
    } finally {
      await ctl('google', { bigDoc: false })
    }
  })
})
