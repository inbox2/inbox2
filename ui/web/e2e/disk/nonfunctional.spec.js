import { createRequire } from 'node:module'
import { test, expect, diskUrl, idUrl, node, openFolder, row, rows, seed, slideOver } from './support.js'

/* Non-functional: tenant isolation through the UI, a keyboard-only walk through
 * the main flow, phone width, and accessibility (axe, when installed). */

const hasAxe = (() => { try { createRequire(import.meta.url).resolve('@axe-core/playwright'); return true } catch { return false } })()

test.describe('Non-functional', () => {
  test('NF tenant isolation: another org\'s folder, file, page and share give the not-found screen', async ({ page }) => {
    for (const key of ['other_folder', 'other_file', 'other_page']) {
      await page.goto(idUrl(node(key)))
      await expect(page.getByRole('alert'), key).toContainText('Not found')
      await expect(page.getByText(/Secret plans|secret\.md|Not for you|Theirs/)).toHaveCount(0)
    }
    await page.goto(diskUrl(`d/${seed.shares['Other Share'].slug}`))
    await expect(page.getByRole('alert')).toContainText('Not found')
    // Asking for an org this person is not in (?org=) leaves them on their own.
    for (const url of [diskUrl('c', 'e2e-other')]) {
      await page.goto(url)
      await expect.poll(() => new URL(page.url()).pathname + new URL(page.url()).search).toBe('/disk/c')
      await expect(page.getByRole('navigation', { name: 'Disk' })).not.toContainText('e2e-other')
    }
  })

  test('NF keyboard only: reach the list, move, open, go up, preview, close, and the menu key', async ({ page }) => {
    await openFolder(page, idUrl(node('launch')), 'Launch 2026')
    // A real row: the loading skeleton's rows hold nothing to Tab to.
    await expect(rows(page).first().getByRole('button').first()).toBeVisible()
    // Tab from the search box into the list.
    await page.getByRole('searchbox', { name: 'Search files and folders' }).focus()
    let inList = false
    for (let i = 0; i < 25 && !inList; i++) {
      await page.keyboard.press('Tab')
      inList = await page.evaluate(() => !!document.activeElement?.closest('tbody'))
    }
    expect(inList).toBe(true)
    await page.keyboard.press('ArrowDown')
    await page.keyboard.press('ArrowUp')
    await page.keyboard.press('Enter')
    await expect(page.getByRole('heading', { level: 1, name: 'Assets' })).toBeVisible()
    await page.keyboard.press('Backspace')
    await expect(page.getByRole('heading', { level: 1, name: 'Launch 2026' })).toBeVisible()
    // Back in the list: open the brief, close it with Esc.
    await row(page, 'brief.md').getByRole('button', { name: 'brief.md' }).focus()
    await page.keyboard.press('Enter')
    await expect(slideOver(page)).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(slideOver(page)).toHaveCount(0)
    // Shift+F10 opens the menu on the focused row; arrows and Enter pick; focus comes back.
    await row(page, 'brief.md').getByRole('button', { name: 'brief.md' }).focus()
    await page.keyboard.press('Shift+F10')
    const menu = page.getByRole('menu')
    await expect(menu).toBeVisible()
    await expect(menu.getByRole('menuitem').first()).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(menu).toHaveCount(0)
    await expect(row(page, 'brief.md').getByRole('button', { name: 'brief.md' })).toBeFocused()
  })

  test('NF phone width: the sidebar collapses, the slide-over goes full screen, browse, preview and download work @smoke', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto(idUrl(node('samples')))
    await expect(page.getByRole('heading', { level: 1, name: 'Samples' })).toBeVisible()
    await expect(page.getByRole('navigation', { name: 'Disk' })).not.toBeInViewport()
    await page.getByRole('button', { name: 'Drives and views' }).click()
    await expect(page.getByRole('navigation', { name: 'Disk' }).getByRole('link', { name: /Shared disk/ })).toBeInViewport()
    await page.keyboard.press('Escape')
    const scrollW = await page.evaluate(() => document.documentElement.scrollWidth)
    expect(scrollW).toBeLessThanOrEqual(390)
    await row(page, 'report.pdf').getByRole('button', { name: 'report.pdf' }).click()
    const panel = slideOver(page)
    const box = await panel.boundingBox()
    expect(box.width).toBeGreaterThanOrEqual(380) // edge to edge, less a hairline inset
    await expect(panel.locator('canvas')).toBeVisible({ timeout: 30_000 })
    const d = page.waitForEvent('download')
    await panel.getByRole('button', { name: 'Download' }).first().click()
    expect((await d).suggestedFilename()).toBe('report.pdf')
  })

  test('NF accessibility: axe finds no serious violations on the main screens', async ({ page }) => {
    test.skip(!hasAxe, '@axe-core/playwright is not installed in ui/web; per the brief it was not added')
    const { default: AxeBuilder } = await import('@axe-core/playwright')
    for (const url of [diskUrl('c'), diskUrl('d'), idUrl(node('samples'))]) {
      await page.goto(url)
      await expect(page.locator('main h1')).toBeVisible()
      const r = await new AxeBuilder({ page }).analyze()
      expect(r.violations.filter((v) => ['serious', 'critical'].includes(v.impact)), url).toEqual([])
    }
  })
})
