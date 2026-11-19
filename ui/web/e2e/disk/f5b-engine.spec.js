import fs from 'node:fs'
import path from 'node:path'
import { test, expect, ORG, api, diskUrl, fetchEngine, folderUrl, idUrl, node, openFolder, row, sample, scratch, slideOver, uploads } from './support.js'
import { ENGINE_PORT, STATE } from './env.js'

/* F5b. The exact-view engine. The harness packs the engine with
 * scripts/disk-engine-pack.mjs into .state/engine and serves it from :4622
 * (engine-server.mjs), with VITE_DISK_ENGINE_URL pointing there, so the whole
 * flow runs: offer, download with progress, the isolated engine window,
 * LibreOffice WASM converting a real docx, exact view in place, the cache. */

const hasEngine = fs.existsSync(path.join(STATE, 'engine', 'manifest.json'))
const ENGINE = `localhost:${ENGINE_PORT}`
const bar = (panel) => panel.getByRole('status').filter({ hasText: /exact view|engine|quick view/i }).first()

test.describe('F5b exact-view engine', () => {
  test('F5b the engine page is cross-origin isolated; Disk, mail and login are not', async ({ page }) => {
    const res = await page.goto('/disk-engine.html')
    expect(res.headers()['cross-origin-opener-policy']).toBe('same-origin')
    expect(res.headers()['cross-origin-embedder-policy']).toBe('require-corp')
    expect(await page.evaluate(() => crossOriginIsolated)).toBe(true)
    for (const route of [`/${ORG}/mail`, '/disk/c', '/login']) {
      const r = await page.goto(route)
      expect(r.headers()['cross-origin-opener-policy']).toBeUndefined()
      expect(await page.evaluate(() => crossOriginIsolated)).toBe(false)
    }
  })

  test('F5b.2 an Office file opens at once in quick view and offers exact view with its size; nothing big is fetched first', async ({ page, context }) => {
    const engineReqs = []
    page.on('request', (r) => { if (r.url().includes(ENGINE)) engineReqs.push(r.url()) })
    // Opening Disk starts nothing: the first Office file does (decided 2026-11-09, TODO 48.2).
    await page.goto(diskUrl('c'))
    await expect(page.getByRole('heading', { name: 'My disk' })).toBeVisible()
    await page.waitForTimeout(1500)
    expect(engineReqs.every((u) => u.endsWith('/manifest.json'))).toBe(true)
    // After a cancel, which is remembered, the same file offers the download and starts nothing.
    await context.addInitScript(() => localStorage.setItem('inbox2_disk_engine_declined', 'yes'))
    await page.goto(idUrl(node('sample_plan_docx')))
    const panel = slideOver(page)
    await expect(page.frameLocator('iframe[title="plan.docx"]').locator('body')).not.toBeEmpty({ timeout: 10_000 })
    await expect(bar(panel)).toContainText(/This is a quick view\. Exact view needs a one-time [\d.]+ MB download\./)
    await expect(panel.getByRole('button', { name: 'Get exact view' })).toBeVisible()
    await page.waitForTimeout(1500)
    expect(engineReqs.every((u) => u.endsWith('/manifest.json'))).toBe(true)
  })

  test('F5b.3 the offer is withheld with data saver on, and on a phone', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: path.join(STATE, 'auth', 'e2e_owner.json') })
    await ctx.addInitScript(() => Object.defineProperty(navigator, 'connection', { value: { saveData: true, effectiveType: '4g', addEventListener() {} } }))
    const page = await ctx.newPage()
    const engineReqs = []
    page.on('request', (r) => { if (r.url().includes(ENGINE) && !r.url().endsWith('manifest.json')) engineReqs.push(r.url()) })
    await page.goto(idUrl(node('sample_plan_docx')))
    const panel = slideOver(page)
    await expect(panel.getByRole('button', { name: 'Download' }).first()).toBeVisible()
    await page.waitForTimeout(1500)
    await expect(panel.getByRole('button', { name: 'Get exact view' })).toHaveCount(0)
    expect(engineReqs).toEqual([])
    await page.setViewportSize({ width: 390, height: 844 })
    await page.reload()
    await expect(slideOver(page)).toBeVisible()
    await expect(slideOver(page).getByRole('button', { name: 'Get exact view' })).toHaveCount(0)
    await ctx.close()
  })

  test('F5b.4-7 download with progress and cancel, the engine window converts, exact view replaces quick view, asks once, survives a reload', async ({ page, context }) => {
    test.skip(!hasEngine, 'the engine was not packed (scripts/disk-engine-pack.mjs); only the offer and fallback paths ran')
    test.setTimeout(240_000)
    // The first Office file starts the download by itself. Slow the engine host so the progress bar has time to show.
    await page.route(`**/${ENGINE}/**`, async (route) => {
      if (!route.request().url().endsWith('manifest.json')) await new Promise((r) => setTimeout(r, 1500))
      await route.continue().catch(() => {}) // cancelled while held
    })
    await page.goto(idUrl(node('sample_plan_docx')))
    let panel = slideOver(page)
    await expect(page.frameLocator('iframe[title="plan.docx"]').locator('body')).not.toBeEmpty({ timeout: 10_000 }) // quick view meanwhile
    await expect(bar(panel)).toContainText('Downloading exact view', { timeout: 30_000 })
    await expect(bar(panel)).toContainText(/MB of [\d.]+ MB/)
    await bar(panel).getByRole('button', { name: 'Cancel' }).click()
    await expect(panel.getByRole('button', { name: 'Get exact view' })).toBeVisible()
    await page.unroute(`**/${ENGINE}/**`)

    // A cancel is remembered: after a reload the file offers the download and fetches no part.
    const afterCancel = []
    const note = (r) => { if (r.url().includes(ENGINE) && !r.url().endsWith('manifest.json')) afterCancel.push(r.url()) }
    page.on('request', note)
    await page.reload()
    panel = slideOver(page)
    await expect(panel.getByRole('button', { name: 'Get exact view' })).toBeVisible()
    await page.waitForTimeout(1500)
    expect(afterCancel).toEqual([])
    page.off('request', note)

    // The real thing: download, verify, convert in the isolated window, exact view in place.
    const popup = context.waitForEvent('page')
    await panel.getByRole('button', { name: 'Get exact view' }).click()
    const engineWindow = await popup
    expect(engineWindow.url()).toContain('/disk-engine')
    await expect(panel.getByText(/^Exact view, made on this device$/)).toBeVisible({ timeout: 180_000 })
    await expect(panel.locator('canvas')).toBeVisible()
    await expect(bar(panel)).toContainText('Always open Office files in exact view on this device?')
    await bar(panel).getByRole('button', { name: 'Yes' }).click()
    expect(await engineWindow.evaluate(() => crossOriginIsolated)).toBe(true)

    // Reload: the engine is cached and this docx was converted here: exact view at once, no engine fetch.
    const engineReqs = []
    page.on('request', (r) => { if (r.url().includes(ENGINE) && !r.url().endsWith('manifest.json')) engineReqs.push(r.url()) })
    await page.reload()
    panel = slideOver(page)
    await expect(panel.getByText(/^Exact view, made on this device$/)).toBeVisible({ timeout: 30_000 })
    expect(engineReqs).toEqual([])

  })

  test('F5b.8 a device with the engine but no engine window open still stores a rendition at upload: one click in the upload panel, or the Upload click itself with "always"', async ({ page, context }) => {
    test.skip(!hasEngine, 'the engine was not packed')
    test.setTimeout(300_000)
    await fetchEngine(page, idUrl(node('sample_plan_docx')))
    const hasRendition = (folderId, name) => async () => {
      const n = (await api('e2e_owner').get(`/nodes/${folderId}/children`)).nodes.find((x) => x.name === name)
      if (!n) return false
      return (await api('e2e_owner').get(`/nodes/${n.id}/versions`)).versions[0].has_rendition
    }
    const upload = async (f, file) => {
      const chooser = page.waitForEvent('filechooser')
      await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
      await (await chooser).setFiles(file)
    }

    // No window open and "always" not chosen: the upload finishes with none, and the panel offers to make it.
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5b-no-window')
    await openFolder(page, folderUrl(f), f.name)
    const used = async () => (await api('e2e_owner').get('/')).c_quota.used_bytes
    const usedBefore = await used()
    await upload(f, sample('plan.docx'))
    await expect(row(page, 'plan.docx')).toBeVisible()
    const make = uploads(page).getByRole('button', { name: 'Make exact view' })
    await expect(make).toBeVisible({ timeout: 30_000 })
    expect(await hasRendition(f.id, 'plan.docx')()).toBe(false)
    const win = context.waitForEvent('page')
    await make.click()
    const engineWindow = await win
    await expect.poll(hasRendition(f.id, 'plan.docx'), { timeout: 120_000 }).toBe(true)
    await expect(make).toHaveCount(0)
    // The rendition does not count against the quota: the meter moved by the docx alone (one worker, nothing else uploads meanwhile).
    expect(await used() - usedBefore).toBe(fs.statSync(sample('plan.docx')).size)
    await engineWindow.close()

    // "Always use exact view" on this device: the Upload click opens the window after the picker, and no panel action is needed.
    await page.evaluate(() => localStorage.setItem('inbox2_disk_exact_always', 'yes'))
    const g = await scratch('e2e_owner', node('owner_c').id, 'f5b-always')
    await openFolder(page, folderUrl(g), g.name)
    const win2 = context.waitForEvent('page')
    await upload(g, sample('plan.docx'))
    await win2
    await expect.poll(hasRendition(g.id, 'plan.docx'), { timeout: 120_000 }).toBe(true)
    await expect(uploads(page).getByRole('button', { name: /Make exact view/ })).toHaveCount(0)
  })

  test('F5b.8 an Office upload from a device with the engine stores an exact-view rendition other devices use; conversions go through the worker and a third tab sees no file bytes', async ({ page, context, as }) => {
    test.skip(!hasEngine, 'the engine was not packed')
    test.setTimeout(240_000)
    // The first Office file on this device fetches the engine.
    await fetchEngine(page, idUrl(node('sample_plan_docx')))
    // A third Disk tab of the same origin listens on the engine channel and on the
    // service worker for the whole run: it must see discovery only, never a file or a PDF.
    const spy = await context.newPage()
    await spy.goto(diskUrl('c'))
    await expect.poll(() => spy.evaluate(() => !!navigator.serviceWorker.controller), { timeout: 15_000 }).toBe(true)
    await spy.evaluate((channel) => {
      window.__heard = []
      const bytesIn = (v, depth = 0) => {
        if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return v.byteLength || 1
        if (v instanceof Blob) return v.size || 1
        if (typeof v === 'string') return v.includes('%PDF') || v.includes('PK' + String.fromCharCode(3, 4)) ? v.length : 0
        if (v && typeof v === 'object' && depth < 5) return Object.values(v).reduce((n, x) => n + bytesIn(x, depth + 1), 0)
        return 0
      }
      const note = (via) => ({ data }) => window.__heard.push({ via, keys: data && typeof data === 'object' ? Object.keys(data) : [], bytes: bytesIn(data) })
      new BroadcastChannel(channel).onmessage = note('channel')
      navigator.serviceWorker.addEventListener('message', note('worker'))
      navigator.serviceWorker.startMessages()
    }, 'inbox2-disk-engine')

    // A finished upload is no click, so it cannot open the engine window; it uses one
    // that is open. Open it the way a person does: exact view on an Office file.
    await page.goto(idUrl(node('sample_plan_docx')))
    const win = context.waitForEvent('page')
    await slideOver(page).getByRole('button', { name: 'Show exact view' }).click()
    await win
    await expect(slideOver(page).getByText(/^Exact view, made on this device$/)).toBeVisible({ timeout: 120_000 })
    await page.keyboard.press('Escape')

    const f = await scratch('e2e_ben', node('samples').id, 'f5b-rendition') // in a share, so Ana can open it
    await openFolder(page, folderUrl(f), f.name)
    const popup = context.waitForEvent('page').catch(() => null)
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(sample('plan.docx'))
    await expect(row(page, 'plan.docx')).toBeVisible()
    await popup
    const docx = async () => (await api('e2e_owner').get(`/nodes/${f.id}/children`)).nodes.find((n) => n.name === 'plan.docx')
    const versionHas = async () => {
      const n = await docx()
      const { versions } = await api('e2e_owner').get(`/nodes/${n.id}/versions`)
      return versions[0].has_rendition
    }
    await expect.poll(versionHas, { timeout: 120_000 }).toBe(true)

    // The spy heard the engine's discovery traffic (so it was listening) and nothing with bytes.
    const heard = await spy.evaluate(() => window.__heard)
    expect(heard.some((m) => m.via === 'channel')).toBe(true)
    expect(heard.filter((m) => m.bytes > 0)).toEqual([])
    expect(heard.filter((m) => m.keys.some((k) => /convert|pdf|bytes/i.test(k)))).toEqual([])

    // Another person, another device with no engine: exact view from the stored rendition.
    const ana = await as('e2e_ana')
    await ana.goto(idUrl(await docx()))
    await expect(slideOver(ana).getByText(/^Exact view$/)).toBeVisible({ timeout: 30_000 })
    await expect(slideOver(ana).getByRole('button', { name: 'Get exact view' })).toHaveCount(0)
  })
})
