import fs from 'node:fs'
import { test, expect, api, folderUrl, idUrl, node, openFolder, row, sample, scratch, slideOver } from './support.js'

/* F5. The preview slide-over: every renderer against the real seeded files in
 * D:\Marketing\Samples, the fallback, Previous/Next, deep link, full screen. */

const open = async (page, key) => {
  await page.goto(idUrl(node(key)))
  const panel = slideOver(page)
  await expect(panel).toBeVisible()
  return panel
}
const frame = (page, name) => page.frameLocator(`iframe[title="${name}"]`)

test.describe('F5 preview slide-over', () => {
  test('F5.1 a file opens in a slide-over with the list behind, Download, Share, details and access; Esc closes; the URL reopens it', async ({ page }) => {
    await openFolder(page, idUrl(node('samples')), 'Samples')
    await row(page, 'notes.md').getByRole('button', { name: 'notes.md' }).click()
    const panel = slideOver(page)
    await expect(panel.getByRole('heading', { name: 'notes.md' })).toBeVisible()
    for (const b of ['Download', 'Share']) await expect(panel.getByRole('button', { name: b, exact: true }).first()).toBeVisible()
    await expect(panel).toContainText('Location')
    await expect(panel).toContainText('D:\\Marketing\\Samples')
    await expect(panel.getByRole('heading', { name: 'Your access' })).toBeVisible()
    await expect(row(page, 'data.csv')).toBeVisible() // the list stays behind it
    const url = page.url()
    expect(url).toMatch(/\?open=notes\.md-/)
    await page.reload()
    await expect(slideOver(page).getByRole('heading', { name: 'notes.md' })).toBeVisible()
    // Previous and Next step through the folder.
    await slideOver(page).getByRole('button', { name: 'Next' }).click()
    await expect(page).not.toHaveURL(/open=notes\.md-/)
    await slideOver(page).getByRole('button', { name: 'Previous' }).click()
    await expect(page).toHaveURL(/open=notes\.md-/)
    await page.keyboard.press('ArrowRight')
    await expect(page).not.toHaveURL(/open=notes\.md-/)
    await page.keyboard.press('Escape')
    await expect(slideOver(page)).toHaveCount(0)
    await expect(page).not.toHaveURL(/open=/)
  })

  test('F5.2 PDF renders with page navigation, zoom and text search @smoke', async ({ page }) => {
    const panel = await open(page, 'sample_report_pdf')
    await expect(panel.locator('canvas')).toBeVisible({ timeout: 30_000 })
    const pageField = panel.getByRole('textbox', { name: 'Page' })
    await expect(pageField).toHaveValue('1')
    await expect(panel).toContainText('/ 5')
    await panel.getByRole('button', { name: 'Next page' }).click()
    await expect(pageField).toHaveValue('2')
    await pageField.fill('5')
    await expect(pageField).toHaveValue('5')
    // It opens fitted to the pane; zooming switches to a percentage.
    await expect(panel.getByText('Fit', { exact: true })).toBeVisible()
    const canvasBox = await panel.locator('canvas').boundingBox()
    expect(canvasBox.width).toBeLessThanOrEqual((await panel.boundingBox()).width)
    await panel.getByRole('button', { name: 'Zoom in' }).click()
    await expect(panel.getByText(/^\d+%$/)).toBeVisible()
    await panel.getByRole('searchbox', { name: 'Find in PDF' }).fill('zebra')
    await panel.getByRole('searchbox', { name: 'Find in PDF' }).press('Enter')
    await expect(pageField).toHaveValue('3')
  })

  test('F5.2 a 200-page PDF opens at page 1 and jumps to page 150', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5-long-pdf')
    const n = await api('e2e_owner').upload(f.id, 'pages200.pdf', fs.readFileSync(sample('pages200.pdf')))
    const t0 = Date.now()
    await page.goto(idUrl(n))
    const panel = slideOver(page)
    await expect(panel.locator('canvas')).toBeVisible({ timeout: 30_000 })
    await expect(panel).toContainText('/ 200')
    const opened = Date.now() - t0
    await panel.getByRole('textbox', { name: 'Page' }).fill('150')
    await expect(panel.getByRole('textbox', { name: 'Page' })).toHaveValue('150')
    expect(opened).toBeLessThan(10_000)
  })

  test('F5.3 images render with zoom and rotate; an SVG with a script renders without running it', async ({ page }) => {
    let panel = await open(page, 'sample_photo_jpg')
    const img = panel.getByRole('img', { name: 'photo.jpg' })
    await expect(img).toBeVisible()
    expect(await img.evaluate((el) => el.naturalWidth)).toBe(800)
    await panel.getByRole('button', { name: '100%' }).click()
    await expect(panel.getByRole('button', { name: 'Fit' })).toBeVisible()
    await panel.getByRole('button', { name: 'Rotate' }).click()
    await expect.poll(() => img.evaluate((el) => getComputedStyle(el).getPropertyValue('--rotate').trim())).toBe('90deg')

    panel = await open(page, 'sample_diagram_svg')
    await expect(panel.getByRole('img', { name: 'diagram.svg' })).toBeVisible()
    expect(await page.evaluate(() => window.__svgRan)).toBeUndefined()
  })

  test('F5.4 video and audio play and seek', async ({ page }) => {
    let panel = await open(page, 'sample_clip_mp4')
    const video = panel.locator('video')
    await expect(video).toBeVisible()
    await expect.poll(() => video.evaluate((v) => v.duration)).toBeGreaterThan(3)
    await video.evaluate((v) => { v.muted = true; v.currentTime = 2; return v.play() })
    await expect.poll(() => video.evaluate((v) => v.currentTime)).toBeGreaterThan(2)
    panel = await open(page, 'sample_voice_m4a')
    const audio = panel.locator('audio')
    await expect.poll(() => audio.evaluate((a) => a.duration)).toBeGreaterThan(3)
    await audio.evaluate((a) => { a.muted = true; a.currentTime = 1.5 })
    await expect.poll(() => audio.evaluate((a) => a.currentTime)).toBeGreaterThanOrEqual(1.5)
  })

  test('F5.4 audio shows a waveform drawn from the decoded audio, with progress, and clicking it seeks', async ({ page }) => {
    const panel = await open(page, 'sample_voice_m4a')
    const wave = panel.getByRole('img', { name: 'Waveform. Click to seek.' })
    await expect(wave).toHaveAttribute('data-ready', 'true')
    const inked = await wave.evaluate((c) => {
      const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data
      let n = 0
      for (let i = 3; i < d.length; i += 4) if (d[i]) n++
      return n
    })
    expect(inked).toBeGreaterThan(100)
    const audio = panel.locator('audio')
    await expect.poll(() => audio.evaluate((a) => a.duration)).toBeGreaterThan(3)
    const box = await wave.boundingBox()
    await page.mouse.click(box.x + box.width * 0.75, box.y + box.height / 2)
    await expect.poll(() => audio.evaluate((a) => a.currentTime / a.duration)).toBeGreaterThan(0.7)
    await expect.poll(async () => Number(await wave.getAttribute('data-progress'))).toBeGreaterThan(0.7)
    // A video gets no waveform.
    await expect((await open(page, 'sample_clip_mp4')).getByRole('img', { name: 'Waveform. Click to seek.' })).toHaveCount(0)
  })

  test('F5.4 a video the browser cannot play shows a clear message and Download', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5-codec')
    const bad = await api('e2e_owner').upload(f.id, 'unplayable.mp4', Buffer.alloc(64 * 1024, 7))
    await page.goto(`${folderUrl(f)}?open=unplayable.mp4-${bad.id.slice(-21)}`)
    const panel = slideOver(page)
    await expect(panel.getByText("This preview didn't work.")).toBeVisible({ timeout: 20_000 })
    await expect(panel.getByRole('button', { name: 'Download' }).first()).toBeVisible()
  })

  test('F5.5 markdown renders with a raw toggle; code, HTML and logs render as code with line numbers', async ({ page }) => {
    let panel = await open(page, 'sample_notes_md')
    await expect(frame(page, 'notes.md').getByRole('heading', { name: 'Release notes' })).toBeVisible()
    await panel.getByRole('button', { name: 'Raw' }).click()
    await expect(panel.locator('pre')).toContainText('# Release notes')

    panel = await open(page, 'sample_app_js')
    await expect(panel.locator('.cm-lineNumbers')).toBeVisible()
    await expect(panel.locator('.cm-content')).toContainText('export function greet')

    // An uploaded .html file previews as code and never runs.
    panel = await open(page, 'sample_page_html')
    await expect(panel.locator('.cm-content')).toContainText('<h1>Uploaded HTML</h1>')
    expect(await page.evaluate(() => window.__htmlRan)).toBeUndefined()

    panel = await open(page, 'sample_server_log')
    await expect(panel.locator('.cm-content')).toContainText('INFO line 1')

    // The .html file downloads as an attachment from the storage origin, never rendered by the app.
    const { download } = await api('e2e_owner').get(`/nodes/${node('sample_page_html').id}/download`)
    expect(new URL(download.url).origin).not.toBe('http://localhost:4621')
    expect((await fetch(download.url)).headers.get('content-disposition')).toMatch(/^attachment/)

    // A 5 MB log opens without freezing the tab: the page keeps answering while it renders.
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5-big-log')
    const big = Array.from({ length: 95_000 }, (_, i) => `2026-10-03T12:00:00Z INFO request ${i + 1} served in ${i % 97} ms`).join('\n')
    const n = await api('e2e_owner').upload(f.id, 'big.log', big)
    expect(Buffer.byteLength(big)).toBeGreaterThan(5 * 1024 * 1024)
    await page.goto(idUrl(n))
    const logPanel = slideOver(page)
    await expect(logPanel.locator('.cm-content')).toContainText('request 1 served', { timeout: 30_000 })
    const t0 = Date.now()
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())))
    expect(Date.now() - t0).toBeLessThan(1000)
  })

  test('F5.6 Word, spreadsheet, CSV and PowerPoint render in a sandboxed frame, labelled approximate', async ({ page }) => {
    let panel = await open(page, 'sample_plan_docx')
    const docFrame = page.locator('iframe[title="plan.docx"]')
    await expect(docFrame).toHaveAttribute('sandbox', 'allow-same-origin')
    await expect.poll(async () => (await frame(page, 'plan.docx').locator('body').innerText()).length, { timeout: 30_000 }).toBeGreaterThan(20)
    await expect(panel).toContainText(/quick view|approximate/i)

    panel = await open(page, 'sample_budget_xlsx')
    await expect(panel.getByRole('tablist', { name: 'Sheets' }).getByRole('tab').first()).toBeVisible({ timeout: 30_000 })
    await expect.poll(async () => frame(page, 'budget.xlsx').locator('td').count()).toBeGreaterThan(3)

    panel = await open(page, 'sample_data_csv')
    await expect(panel.locator('table')).toContainText('revenue')
    await expect(panel.locator('table')).toContainText('Q3')

    await open(page, 'sample_deck_pptx')
    await expect.poll(async () => (await frame(page, 'deck.pptx').locator('body').innerHTML()).length, { timeout: 30_000 }).toBeGreaterThan(200)
  })

  test('F5.7 a zip lists its entries and opens one on its own', async ({ page }) => {
    const ranges = []
    page.on('request', (r) => { if (r.url().includes(':4900/') && r.headers().range) ranges.push(r.headers().range) })
    const panel = await open(page, 'sample_bundle_zip')
    await expect(panel.getByRole('button', { name: 'notes.md' })).toBeVisible()
    await expect(panel.getByRole('button', { name: 'data.csv' })).toBeVisible()
    expect(ranges.length).toBeGreaterThan(0) // read with range requests
    await panel.getByRole('button', { name: 'notes.md' }).click()
    await expect(panel.locator('pre')).toContainText('# Release notes')
  })

  test('F5.7 a 1 GB zip lists its entries after fetching only its tail (E2E_DISK_LARGE)', async ({ page }) => {
    test.skip(!process.env.E2E_DISK_LARGE, 'set E2E_DISK_LARGE=1 to run the 1 GB case')
    test.setTimeout(600_000)
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5-gb-zip')
    const n = await api('e2e_owner').upload(f.id, 'one-gb.zip', fs.readFileSync(sample('one-gb.zip')))
    let fetched = 0
    page.on('requestfinished', async (r) => { if (r.url().includes(':4900/')) fetched += Number((await r.response())?.headers()['content-length'] || 0) })
    await page.goto(idUrl(n))
    await expect(slideOver(page).getByRole('button', { name: 'notes.md' })).toBeVisible({ timeout: 60_000 })
    expect(fetched).toBeLessThan(5 * 1024 * 1024)
  })

  test('F5.8 a type with no renderer shows the type icon, details and Download, not an error', async ({ page }) => {
    const panel = await open(page, 'sample_design_fig')
    await expect(panel).toContainText('There is no preview for this type of file yet.')
    await expect(panel.getByRole('button', { name: 'Download' }).last()).toBeVisible()
    await expect(panel).not.toContainText("didn't work")
  })

  test('F5.9 a corrupt PDF falls back to the no-preview state and the failure is counted', async ({ page }) => {
    const failures = page.waitForRequest((r) => r.url().endsWith('/preview-failures') && r.method() === 'POST')
    const panel = await open(page, 'sample_broken_pdf')
    await expect(panel).toContainText("This preview didn't work.")
    const req = await failures
    expect(req.postDataJSON()).toMatchObject({ renderer: 'pdf' })
    const { events } = await api('e2e_owner').get(`/nodes/${node('sample_broken_pdf').id}/events`)
    expect(events.find((e) => e.action === 'preview_failed')).toBeUndefined() // kept out of the activity feed
  })

  test('F5.10 an uploaded image gets a browser-made thumbnail shown in the grid', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f5-thumb')
    await openFolder(page, folderUrl(f), f.name)
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(sample('photo.jpg'))
    await expect(row(page, 'photo.jpg')).toBeVisible()
    await expect.poll(async () => (await api('e2e_owner').get(`/nodes/${f.id}/children`)).nodes[0].has_thumbnail, { timeout: 20_000 }).toBe(true)
    await page.reload()
    await page.getByRole('button', { name: 'Grid view' }).click()
    const t = page.getByRole('listbox', { name: 'Items' }).getByRole('option').filter({ hasText: 'photo.jpg' })
    await expect(t.locator('img')).toBeVisible()
    await page.getByRole('button', { name: 'List view' }).click()
  })

  test('F5.11 browsing Disk downloads no PDF, Office or editor bundle', async ({ page }) => {
    const loaded = []
    page.on('request', (r) => loaded.push(r.url()))
    await page.goto(idUrl(node('samples')))
    await expect(row(page, 'notes.md')).toBeVisible()
    await page.goto(idUrl(node('launch')))
    await expect(row(page, 'brief.md')).toBeVisible()
    const heavy = loaded.filter((u) => /PdfPreview|pdfium|DocxPreview|SheetPreview|PptxPreview|libreoffice|PageView|tiptap|codemirror/i.test(u))
    expect(heavy).toEqual([])
  })

  test('F5 full screen preview, and a deep link to a file opens it on its folder', async ({ page }) => {
    const panel = await open(page, 'sample_photo_jpg')
    await expect(page).toHaveURL(/\/disk\/d\/marketing\/Samples-[^?]+\?open=photo\.jpg-/)
    await panel.getByRole('button', { name: 'Full screen' }).click()
    await expect(panel.getByRole('button', { name: 'Exit full screen' })).toHaveAttribute('aria-pressed', 'true')
    const box = await panel.locator('[class*="paneFull"]').boundingBox()
    expect(box.width).toBeGreaterThan(1000)
    await panel.getByRole('button', { name: 'Exit full screen' }).click()
  })
})
