import { execFileSync } from 'node:child_process'
import { format } from 'date-fns'
import { test, expect, api, node, scratch, seed, uniq, user } from './support.js'
import { RAILS } from './env.js'

/* F11. The console's Disk page, link admin, offboarding and the org export. */

test.describe('F11 admin and offboarding', () => {
  test('F11.1 /console/disk shows usage per member and per share that add up to the meter, and the link setting', async ({ page }) => {
    const { usage } = await api('e2e_owner').get('/admin/usage')
    await page.goto('/console/disk')
    await expect(page.getByRole('heading', { level: 1, name: 'Disk' })).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Space' })).toBeVisible()
    await expect(page.getByText(/Files .*, older versions .*, Trash .*\./)).toBeVisible()
    const byShare = page.locator('table').filter({ has: page.getByRole('columnheader', { name: 'Share', exact: true }) })
    await expect(byShare).toContainText('Marketing')
    const parts = usage.members.reduce((s, r) => s + r.bytes, 0) + usage.shares.reduce((s, r) => s + r.bytes, 0)
    expect(parts).toBe(usage.quota.used_bytes)
    await expect(page.getByRole('switch', { name: 'Allow public links' }).or(page.getByRole('checkbox', { name: 'Allow public links' }))).toBeChecked()
  })

  test('F11.3 admins list and revoke any public link; a revoked link stops at once', async ({ page }) => {
    const target = await api('e2e_ben').upload(seed.shares.Marketing.root_id, `${uniq('linked').replace(' ', '-')}.md`, '# l\n') // a share: C:\ is the person's own, outside the org's console
    const { link } = await api('e2e_ben').post(`/nodes/${target.id}/links`, {})
    expect((await fetch(`${RAILS}/api/v1/disk/links/${link.token}`)).status).toBe(200)
    await page.goto('/console/disk')
    const line = page.getByRole('row').filter({ hasText: target.name }).filter({ has: page.getByRole('button', { name: 'Revoke' }) }) // not its Activity rows
    await expect(line).toContainText('Ben Member')
    await line.getByRole('button', { name: 'Revoke' }).click()
    await page.getByRole('dialog').getByRole('button', { name: 'Revoke' }).click()
    await expect(line).toHaveCount(0)
    expect((await fetch(`${RAILS}/api/v1/disk/links/${link.token}`)).status).toBe(404)
  })

  test('F11.4 the slide-over shows a file\'s activity; the API gives a share\'s', async ({ page }) => {
    await page.goto(`/disk/shared/x-${node('launch_brief').short_id}`)
    const panel = page.getByRole('dialog')
    await expect(panel.getByRole('heading', { name: 'Activity' })).toBeVisible()
    await expect(panel).toContainText('Ben Member uploaded it')
    const { events } = await api('e2e_owner').get(`/nodes/${seed.shares.Marketing.root_id}/events`)
    expect(events.length).toBeGreaterThan(0)
  })

  test('F11.4 the console shows a share\'s activity, filtered by share, person, action and date', async ({ page }) => {
    const name = uniq('activity')
    await api('e2e_ana').post('/nodes', { parent_id: seed.shares.Marketing.root_id, name, kind: 'folder' })
    await page.goto('/console/disk')
    const card = page.locator('[aria-busy]').filter({ has: page.getByRole('heading', { name: 'Activity' }) })
    await expect(card.getByRole('row').filter({ hasText: name })).toBeVisible()
    await card.getByRole('combobox', { name: 'Share' }).selectOption({ label: 'Marketing' })
    await card.getByRole('combobox', { name: 'Person' }).selectOption({ label: 'Ana Member' })
    await card.getByRole('combobox', { name: 'Action' }).selectOption('created')
    // From today, through the catalog date picker (never a native date input).
    await card.getByRole('button', { name: 'From' }).click()
    await page.getByRole('dialog', { name: 'Choose a date' }).getByRole('button', { name: format(new Date(), 'EEEE d MMMM yyyy') }).click()
    const line = card.getByRole('row').filter({ hasText: name })
    await expect(line).toContainText('Ana Member')
    await expect(line).toContainText('created it')
    await expect(line).toContainText('Marketing')
    await expect(card.locator('tbody tr').filter({ hasNotText: 'Ana Member' })).toHaveCount(0)
    expect(await card.locator('input[type="date"]').count()).toBe(0)
    await card.getByRole('combobox', { name: 'Person' }).selectOption({ label: 'Ben Member' })
    await expect(line).toHaveCount(0)
    await card.getByRole('button', { name: 'Clear filters' }).click()
    await expect(card.getByRole('row').filter({ hasText: name })).toBeVisible()
    // Members are refused.
    expect((await api('e2e_ana').call('GET', '/admin/events')).status).toBe(403)
  })

  test('F11.5 the org export is a zip of C/<member>/ and D/<share>/ with pages as .md and a manifest', async ({ page }) => {
    test.setTimeout(120_000)
    // An older version and a trashed file, each with a marker that must not reach the zip.
    const tag = Date.now().toString(36)
    const f = await scratch('e2e_owner', seed.shares.Marketing.root_id, 'f11-export') // a share: the org export holds team shares only
    const kept = await api('e2e_owner').upload(f.id, 'kept.md', `OLDVERSION${tag}\n`)
    await api('e2e_owner').upload(f.id, 'kept.md', `CURRENT${tag}\n`, { node_id: kept.id, parent_id: undefined })
    const gone = await api('e2e_owner').upload(f.id, 'gone.md', `TRASHED${tag}\n`)
    await api('e2e_owner').del(`/nodes/${gone.id}`)
    await api('e2e_owner').put(`/nodes/${f.id}/grants/${user('e2e_vic').membership_id}`, { role: 'view' }) // a by-name grant for the manifest
    await page.goto('/console/disk')
    await page.evaluate(() => { delete window.showSaveFilePicker }) // the Blob path; a headless browser cannot answer the picker
    const d = page.waitForEvent('download', { timeout: 90_000 })
    await page.getByRole('button', { name: 'Start export' }).click()
    const zip = await d
    const listing = execFileSync('unzip', ['-l', await zip.path()], { encoding: 'utf8' })
    expect(listing).not.toMatch(/\sC\//) // C:\ is the person's own (2026-11-09): no C/<member>/ in the org export
    expect(listing).toMatch(/D\/Marketing\/Samples\/report\.pdf/)
    expect(listing).toMatch(/D\/Marketing\/Launch plan\.md/)
    expect(listing).toMatch(/manifest\.json/)
    const zipPath = await zip.path()
    const manifest = JSON.parse(execFileSync('unzip', ['-p', zipPath, 'manifest.json'], { encoding: 'utf8' }))
    expect(manifest.note).toMatch(/Trash and older versions are not included/)
    expect(manifest.members.map((m) => m.name)).toEqual(expect.arrayContaining(['Olivia Owner', 'Ana Member']))
    expect(manifest.members.every((m) => !m.folder)).toBe(true)
    const marketing = manifest.shares.find((x) => x.name === 'Marketing')
    expect(marketing.folder).toBe('D/Marketing')
    expect(marketing.members.length).toBeGreaterThan(0)
    expect(manifest.grants.length).toBeGreaterThan(0)
    expect(manifest.grants[0]).toHaveProperty('role')
    expect(manifest.links.length).toBeGreaterThan(0)
    expect(manifest.links[0]).toHaveProperty('path')
    const all = execFileSync('unzip', ['-p', zipPath], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
    expect(all).toContain(`CURRENT${tag}`)
    expect(all).not.toContain(`OLDVERSION${tag}`)
    expect(all).not.toContain(`TRASHED${tag}`)
    await expect(page.getByRole('status').filter({ hasText: /Export saved with \d+ items/ })).toBeVisible()
    // Members cannot export.
    expect((await api('e2e_ana').call('GET', '/admin/export')).status).toBe(403)
    void scratch
  })
})
