import fs from 'node:fs'
import { test, expect, api, crumbs, folderUrl, idUrl, newItem, node, openFolder, row, scratch, share, slideOver, uniq, user } from './support.js'

/* F6. Pages: the editor, autosave, export, sub-pages, embeds, history, and
 * live collaboration between two real browsers signed in as two members. */

const editor = (page) => page.locator('article .ProseMirror')
const status = (page) => page.locator('main').getByRole('status').first()
const pageUrl = (n) => idUrl({ name: n.name, short_id: n.short_id || n.id.slice(-21) })

// A small real .docx: Heading 1 and 2 styles, a bullet and a numbered list, a
// table, bold, italic, a link and one picture, zipped the way Word lays it out.
async function wordFile() {
  const { ZipWriter, BlobWriter, TextReader } = await import('@zip.js/zip.js')
  const NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
  const r = (t, pr = '') => `<w:r>${pr ? `<w:rPr>${pr}</w:rPr>` : ''}<w:t xml:space="preserve">${t}</w:t></w:r>`
  const p = (body, ppr = '') => `<w:p>${ppr ? `<w:pPr>${ppr}</w:pPr>` : ''}${body}</w:p>`
  const li = (t, num) => p(r(t), `<w:numPr><w:ilvl w:val="0"/><w:numId w:val="${num}"/></w:numPr>`)
  const cell = (t) => `<w:tc>${p(r(t))}</w:tc>`
  const parts = {
    '[Content_Types].xml': '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels': '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/_rels/document.xml.rels': '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/" TargetMode="External"/></Relationships>',
    'word/styles.xml': `<?xml version="1.0"?><w:styles ${NS}><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style></w:styles>`,
    'word/numbering.xml': `<?xml version="1.0"?><w:numbering ${NS}><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>`,
    'word/document.xml': `<?xml version="1.0"?><w:document ${NS}><w:body>${[
      p(r('Launch brief'), '<w:pStyle w:val="Heading1"/>'),
      p(r('Some ') + r('bold', '<w:b/>') + r(' and ') + r('italic', '<w:i/>') + r(' text, see ') + `<w:hyperlink r:id="rId5">${r('the site')}</w:hyperlink>`),
      p(r('Goals'), '<w:pStyle w:val="Heading2"/>'),
      li('Ship Disk', 1), li('Import Drive', 1),
      li('Plan', 2), li('Build', 2),
      `<w:tbl><w:tr>${cell('Channel')}${cell('Q4')}</w:tr><w:tr>${cell('Paid social')}${cell('15,000')}</w:tr></w:tbl>`,
      p('<w:r><w:drawing/></w:r>'),
    ].join('')}</w:body></w:document>`,
  }
  const zip = new ZipWriter(new BlobWriter('application/vnd.openxmlformats-officedocument.wordprocessingml.document'))
  for (const [name, xml] of Object.entries(parts)) await zip.add(name, new TextReader(xml))
  return Buffer.from(await (await zip.close()).arrayBuffer())
}

async function openPage(page, n) {
  await page.goto(pageUrl(n))
  await expect(page.locator('article > h1')).toHaveText(n.name)
  await expect(editor(page)).toBeVisible()
}

test.describe('F6 pages', () => {
  test('F6.1 New page makes a page in the folder and opens it full screen; Done returns to the folder', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f6-new')
    await openFolder(page, folderUrl(f), f.name)
    await newItem(page, 'Page')
    await expect(page.getByRole('heading', { level: 1, name: 'Untitled' })).toBeVisible()
    await expect(editor(page)).toBeVisible()
    // Full screen: the page covers the Disk sidebar.
    const shell = await page.locator('article').locator('xpath=ancestor::div[contains(@class, "shell")][1]').boundingBox()
    expect(shell.x).toBe(0)
    expect(shell.width).toBe(1440)
    await page.getByRole('button', { name: 'Done' }).click()
    await expect(page.getByRole('heading', { level: 1, name: f.name })).toBeVisible()
    await expect(row(page, 'Untitled')).toBeVisible()
    await expect(row(page, 'Untitled').locator('svg').first()).toBeVisible()
  })

  test('F6.2 the editor has headings, lists, to-dos, tables, code and a slash menu; "## " makes a heading', async ({ page }) => {
    const n = await api('e2e_owner').page(node('owner_c').id, uniq('f6-blocks'))
    await openPage(page, n)
    await editor(page).click()
    await page.keyboard.type('## Big title')
    await expect(editor(page).locator('h2')).toHaveText('Big title')
    await page.keyboard.press('Enter')
    await page.keyboard.type('/')
    const menu = page.getByRole('menu', { name: 'Insert a block' })
    await expect(menu).toBeVisible()
    for (const b of ['Heading 1', 'Bulleted list', 'To-do list', 'Table', 'Code block', 'Callout', 'File from Disk', 'Sub-page']) {
      await expect(menu.getByRole('menuitem', { name: new RegExp(`^${b}`) })).toBeVisible()
    }
    await menu.getByRole('menuitem', { name: /^To-do list/ }).click()
    await page.keyboard.type('Check this')
    await expect(editor(page).locator('ul[data-type="taskList"] li')).toContainText('Check this')
    await page.keyboard.press('Enter')
    await page.keyboard.press('Enter')
    await page.keyboard.type('/')
    await page.getByRole('menu', { name: 'Insert a block' }).getByRole('menuitem', { name: /^Table/ }).click()
    await expect(editor(page).locator('table')).toBeVisible()
  })

  test('F6.3 autosave: typed text is saved and still there after a reload', async ({ page }) => {
    const n = await api('e2e_owner').page(node('owner_c').id, uniq('f6-save'))
    await openPage(page, n)
    await editor(page).click()
    await page.keyboard.type('Saved without a button')
    await expect(status(page)).toHaveText('Saved', { timeout: 15_000 })
    await page.reload()
    await expect(editor(page)).toContainText('Saved without a button')
  })

  test('F6.4 a page made from markdown opens with its blocks, and exports as .md that keeps them', async ({ page }) => {
    await openPage(page, node('launch_plan'))
    await expect(editor(page).locator('h2').filter({ hasText: 'Goals' })).toBeVisible()
    await expect(editor(page).locator('ul[data-type="taskList"]')).toContainText('Write the post')
    await expect(editor(page).locator('table')).toContainText('Week')
    await expect(editor(page).locator('pre')).toContainText('echo launch')
    const d = page.waitForEvent('download')
    await page.getByRole('button', { name: 'Export .md' }).click()
    const file = await d
    expect(file.suggestedFilename()).toBe('Launch plan.md')
    const md = fs.readFileSync(await file.path(), 'utf8')
    for (const s of ['## Goals', '- Ship Disk', '- [ ] Write the post', '- [x] Book the venue', '| Week', '```']) expect(md).toContain(s)

    // Re-import it as a new page: the blocks survive the round trip.
    const back = await api('e2e_owner').page(node('owner_c').id, uniq('f6-reimport'))
    await openPage(page, back)
    const chooser = page.waitForEvent('filechooser')
    await page.getByRole('button', { name: 'Import .md' }).click()
    await (await chooser).setFiles(await file.path())
    await page.getByRole('dialog').getByRole('button', { name: 'Replace' }).click()
    await expect(editor(page).locator('h2').filter({ hasText: 'Goals' })).toBeVisible()
    await expect(editor(page).locator('ul[data-type="taskList"]')).toContainText('Write the post')
    await expect(editor(page).locator('ul[data-type="taskList"] li[data-checked="true"]')).toContainText('Book the venue')
    await expect(editor(page).locator('table')).toContainText('Week')
    await expect(editor(page).locator('pre')).toContainText('echo launch')
  })

  test('F6.5 a sub-page from the slash menu shows in the left rail; breadcrumbs stay on top and lead out', async ({ page }) => {
    const parent = await scratch('e2e_owner', node('owner_c').id, 'f6-tree')
    const n = await api('e2e_owner').page(parent.id, uniq('Parent page'))
    await openPage(page, n)
    await editor(page).click()
    await page.keyboard.type('/')
    await page.getByRole('menu', { name: 'Insert a block' }).getByRole('menuitem', { name: 'Sub-page' }).click()
    await expect(editor(page).locator('a')).toContainText('Untitled')
    const rail = page.getByRole('complementary', { name: 'Pages here' })
    await expect(rail.getByRole('link', { name: n.name })).toBeVisible()
    await expect(rail.getByRole('link', { name: 'Untitled' })).toBeVisible()
    await expect(crumbs(page)).toContainText(parent.name)
    await crumbs(page).getByRole('button', { name: parent.name }).click()
    await expect(page.getByRole('heading', { level: 1, name: parent.name })).toBeVisible()
  })

  test('F6.6 an embedded Disk file opens its preview, and a reader without access sees a locked card', async ({ page, as }) => {
    const n = await api('e2e_admin').page(node('samples').id, uniq('f6-embed'))
    const admin = await as('e2e_admin')
    await openPage(admin, n)
    await editor(admin).click()
    await admin.keyboard.type('/')
    await admin.getByRole('menu', { name: 'Insert a block' }).getByRole('menuitem', { name: 'File from Disk' }).click()
    const pick = admin.getByRole('dialog')
    await pick.getByRole('button', { name: /^Finance/ }).click()
    await pick.getByRole('button', { name: /^budget\.xlsx/ }).click()
    await expect(editor(admin).getByRole('button', { name: /budget\.xlsx/ })).toBeVisible()
    await expect(status(admin)).toHaveText('Saved', { timeout: 15_000 })
    await editor(admin).getByRole('button', { name: /budget\.xlsx/ }).click()
    await expect(slideOver(admin).getByRole('heading', { name: 'budget.xlsx' })).toBeVisible()

    // Ana reads the page (Marketing) but cannot open Finance's file.
    const ana = await as('e2e_ana')
    await openPage(ana, n)
    await expect(editor(ana)).toContainText("You don't have access to this file.")
    void page
  })

  test('F6.7 page history lists versions and restores an older one', async ({ page }) => {
    const n = await api('e2e_ben').page(node('samples').id, uniq('f6-history'))
    await api('e2e_ben').put(`/pages/${n.id}`, { ydoc: null, markdown: '# First words\n', base_revision: 0 })
    await openPage(page, n) // as the owner: a second author starts a second history entry
    await expect(editor(page)).toContainText('First words')
    await editor(page).click()
    await page.keyboard.press('End')
    await page.keyboard.type(' and more')
    await expect(status(page)).toHaveText('Saved', { timeout: 15_000 })
    await page.getByRole('button', { name: 'History', exact: true }).click()
    const panel = slideOver(page)
    await expect(panel.locator('li')).toHaveCount(2)
    await panel.locator('li').nth(1).getByRole('button').first().click()
    await expect(panel.locator('pre')).toContainText('# First words')
    await panel.locator('li').nth(1).getByRole('button', { name: 'Restore' }).click()
    await expect(editor(page)).not.toContainText('and more')
    await expect(status(page)).toHaveText('Saved', { timeout: 15_000 })
    const saved = await api('e2e_owner').get(`/pages/${n.id}`)
    expect(saved.page.markdown).not.toContain('and more')
  })

  test('F6.8 two members edit one page live: both see both, presence shows, a viewer is read-only, revoked access ends the session', async ({ as }) => {
    test.setTimeout(120_000)
    const n = await api('e2e_ben').page(node('samples').id, uniq('f6-live'))
    // Nina joins Marketing as an editor for this test, so her access can be taken away mid-session.
    await api('e2e_ben').put(`/shares/${share('Marketing').id}/members/${user('e2e_new').membership_id}`, { role: 'edit' })
    const ben = await as('e2e_ben')
    const nina = await as('e2e_new')
    const vic = await as('e2e_vic')
    await openPage(ben, n)
    await openPage(nina, n)
    await openPage(vic, n)

    await expect(ben.getByLabel(/2 other people here/)).toBeVisible({ timeout: 15_000 })
    await editor(ben).click()
    await ben.keyboard.type('Ben was here. ')
    await expect(editor(nina)).toContainText('Ben was here.')
    await editor(nina).click()
    await nina.keyboard.press('End')
    await nina.keyboard.type('Nina too.')
    await expect(editor(ben)).toContainText('Nina too.')
    await expect(editor(vic)).toContainText('Nina too.')
    // Carets carry the person's name.
    await expect(editor(nina).getByText('Ben Member', { exact: true })).toBeVisible()
    // Both converge with no lost text, and it is saved.
    await expect(status(ben)).toHaveText('Saved', { timeout: 15_000 })
    await expect.poll(async () => (await api('e2e_ben').get(`/pages/${n.id}`)).page.markdown, { timeout: 15_000 }).toMatch(/Ben was here\. ?Nina too\./)
    const text = (p) => editor(p).locator('p').first().evaluate((el) => { const c = el.cloneNode(true); c.querySelectorAll('.collaboration-carets__caret').forEach((x) => x.remove()); return c.textContent })
    expect(await text(ben)).toBe(await text(nina))

    // The viewer cannot type.
    await expect(status(vic)).toHaveText('View only')
    await expect(editor(vic)).toHaveAttribute('contenteditable', 'false')

    // Nina's access is taken away while she has the page open.
    await api('e2e_ben').del(`/shares/${share('Marketing').id}/members/${user('e2e_new').membership_id}`)
    await expect(status(nina)).toHaveText('Your access to this page ended', { timeout: 15_000 })
    await expect(editor(nina)).toHaveAttribute('contenteditable', 'false')
  })

  test('F6.9 Edit as page on a .md file opens the editor and saving writes the file back as markdown, a new version', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f6-edit-md')
    const file = await api('e2e_owner').upload(f.id, 'README.md', '# Readme\n\n- one\n- two\n')
    await openFolder(page, folderUrl(f), f.name)
    await row(page, 'README.md').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Edit as page' }).click()
    await expect(page.locator('article > h1')).toHaveText('README.md')
    await expect(editor(page).locator('h1')).toHaveText('Readme')
    await expect(editor(page).locator('li')).toHaveCount(2)
    await editor(page).locator('li').last().click()
    await page.keyboard.press('End')
    await page.keyboard.press('Enter')
    await page.keyboard.type('three')
    await page.getByRole('button', { name: 'Save', exact: true }).click()
    await expect(status(page)).toHaveText('Saved as a new version')
    const { versions } = await api('e2e_owner').get(`/nodes/${file.id}/versions`)
    expect(versions).toHaveLength(2)
    const { download } = await api('e2e_owner').get(`/nodes/${file.id}/download`)
    expect(await (await fetch(download.url)).text()).toBe('# Readme\n\n- one\n- two\n- three\n')
    // Done goes back to the folder with the file previewed; a .md is still a file, not a page.
    await page.getByRole('button', { name: 'Done' }).click()
    await expect(slideOver(page)).toBeVisible()
    await expect(row(page, 'README.md')).toBeVisible()
  })

  test('F6.9 Import as page turns a .docx into a page: headings, lists, tables, bold, italic and links; images left out and said so', async ({ page }) => {
    const f = await scratch('e2e_owner', node('owner_c').id, 'f6-docx')
    await api('e2e_owner').upload(f.id, 'Brief.docx', await wordFile())
    await openFolder(page, folderUrl(f), f.name)
    await row(page, 'Brief.docx').click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Import as page' }).click()
    await expect(page.getByRole('status').filter({ hasText: 'Imported as the page "Brief", without its image.' })).toBeVisible()
    await row(page, 'Brief').getByRole('button', { name: /^Brief(\s|$)/ }).click()
    await expect(page.locator('article > h1')).toHaveText('Brief')
    const ed = editor(page)
    await expect(ed.locator('h1')).toHaveText('Launch brief')
    await expect(ed.locator('h2')).toHaveText('Goals')
    await expect(ed.locator('ul li')).toHaveText(['Ship Disk', 'Import Drive'])
    await expect(ed.locator('ol li')).toHaveText(['Plan', 'Build'])
    await expect(ed.locator('table tr')).toHaveCount(2)
    await expect(ed.locator('table')).toContainText('Paid social')
    await expect(ed.locator('strong')).toHaveText('bold')
    await expect(ed.locator('em')).toHaveText('italic')
    await expect(ed.locator('a')).toHaveAttribute('href', 'https://example.com/')
    await expect(ed.locator('img')).toHaveCount(0)
  })
})
