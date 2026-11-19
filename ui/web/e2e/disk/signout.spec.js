import { test, expect, newItem, seed, freshSession, TOKEN_KEY } from './support.js'
import { newSealedShare, appImport, ORG_ID } from './sealedSupport.js'

/* One signed-out experience across tabs (owner request, 2026-10-04). Signing out
 * in one tab reaches every other tab of the origin at once (lib/authBroadcast.js),
 * with no request: they drop their keys and caches and show the blocking
 * "You are signed out" screen (components/SignedOutScreen), which leads back to
 * the same URL. Each test signs in afresh through the API, so signing out ends
 * that session only and never the seeded ones the other specs use. */

const screen = (page) => page.getByRole('alertdialog', { name: 'You are signed out' })
async function signOutIn(page) {
  await page.goto('/settings')
  await page.getByRole('button', { name: 'Log out' }).click()
  await expect(page).toHaveURL(/\/login/)
}
async function signIn(page, username) {
  await page.getByLabel('Username').fill(username)
  await page.getByLabel('Password').fill(seed.password)
  await page.locator('button[type=submit]').click()
}

test.describe('signing out reaches every tab', () => {
  test('signing out in one tab shows the screen in the other within a second, with no request; its sealed keys are gone; Sign in again returns to the same URL', async ({ browser }) => {
    test.setTimeout(120_000)
    const ctx = await freshSession(browser, 'e2e_sol')
    const [a, b] = [await ctx.newPage(), await ctx.newPage()]
    const share = await newSealedShare(b, `Tabs ${Date.now().toString(36)}`)
    const here = new URL(b.url()).pathname
    await appImport(b)
    const keyHeld = () => b.evaluate(async ({ org, id }) => !!(await window.__appImport('/src/lib/disk/sealed.js')).scopeFor(org, id), { org: ORG_ID(), id: share.root_node_id })
    expect(await keyHeld()).toBe(true)

    await a.goto('/settings')
    const asked = []
    b.on('request', (r) => { if (r.url().includes('/api/')) asked.push(r.url()) })
    const statuses = []
    b.on('response', (r) => statuses.push(r.status()))
    const t0 = Date.now()
    await a.getByRole('button', { name: 'Log out' }).click()
    await expect(screen(b)).toBeVisible({ timeout: 1000 })
    expect(Date.now() - t0).toBeLessThan(1500)
    expect(statuses).not.toContain(401) // it came from the other tab, not from a refused request
    expect(asked.filter((u) => !u.includes('/auth/logout'))).toEqual([])
    await expect(screen(b).getByRole('button', { name: 'Sign in again' })).toBeFocused()
    expect(await keyHeld()).toBe(false)
    expect(await b.evaluate((k) => localStorage.getItem(k), TOKEN_KEY)).toBeNull()

    await screen(b).getByRole('button', { name: 'Sign in again' }).click()
    await expect(b).toHaveURL(new RegExp(`/login\\?next=${encodeURIComponent(here).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`))
    await signIn(b, 'e2e_sol')
    await expect(b).toHaveURL(new RegExp(`${here}$`))
    await expect(b.locator('main h1')).toHaveText(share.name)
    await ctx.close()
  })

  test('the same account signing in again in another tab clears the screen, and the tab carries on with its unsaved text', async ({ browser }) => {
    test.setTimeout(90_000)
    const ctx = await freshSession(browser, 'e2e_ben')
    const [a, b] = [await ctx.newPage(), await ctx.newPage()]
    // An open page with text typed in it.
    await b.goto('/disk/c')
    await newItem(b, 'Page')
    const editor = b.locator('.ProseMirror')
    await expect(editor).toBeVisible({ timeout: 20_000 })
    // Saves hang (a slow network), so what is typed is still on its way when the session ends.
    await b.route('**/disk/pages/**', (route) => (route.request().method() === 'GET' ? route.continue() : new Promise(() => {})))
    await editor.click()
    await b.keyboard.type('Words that must survive a sign-out')
    const here = b.url()

    await signOutIn(a)
    await expect(screen(b)).toBeVisible({ timeout: 1000 })
    await expect(screen(b)).toContainText('may not have been saved')
    await expect(screen(b).getByRole('listitem').filter({ hasText: /^Page/ })).toBeVisible()

    await signIn(a, 'e2e_ben')
    await expect(screen(b)).toHaveCount(0, { timeout: 5000 })
    expect(b.url()).toBe(here) // no reload, no navigation
    await expect(editor).toContainText('Words that must survive a sign-out')
    await ctx.close()
  })

  test('another account signing in reloads a signed-out tab to that account\'s home, never the previous account\'s page', async ({ browser }) => {
    test.setTimeout(90_000)
    const ctx = await freshSession(browser, 'e2e_sol')
    const [a, b] = [await ctx.newPage(), await ctx.newPage()]
    await b.goto('/disk/c')
    await expect(b.getByRole('heading', { name: 'My disk' })).toBeVisible({ timeout: 30_000 })
    await signOutIn(a)
    await expect(screen(b)).toBeVisible({ timeout: 1000 })
    const reloaded = b.waitForEvent('load')
    await signIn(a, 'e2e_sam')
    await reloaded
    await expect(screen(b)).toHaveCount(0)
    expect(new URL(b.url()).pathname).not.toBe('/disk/c')
    const who = await b.evaluate(async () => (await (await fetch('/api/v1/account', { headers: { Authorization: `Bearer ${localStorage.getItem('inbox2_cloud_auth_token')}` } })).json()).account.username)
    expect(who).toBe('e2e_sam')
    await ctx.close()
  })

  test('mail, calendar and the console show the same screen, the console in its light skin @smoke', async ({ browser }) => {
    test.setTimeout(90_000)
    const ctx = await freshSession(browser, 'e2e_owner')
    const a = await ctx.newPage()
    const tabs = {}
    for (const [k, url] of [['mail', '/e2e-disk/mail'], ['calendar', '/e2e-disk/calendar'], ['console', '/console/disk']]) {
      tabs[k] = await ctx.newPage()
      await tabs[k].goto(url)
      await tabs[k].waitForLoadState('networkidle').catch(() => {})
    }
    await signOutIn(a)
    for (const p of Object.values(tabs)) await expect(screen(p)).toBeVisible({ timeout: 1000 })
    expect(await screen(tabs.console).evaluate((el) => !!el.closest('.management'))).toBe(true)
    expect(await screen(tabs.mail).evaluate((el) => !!el.closest('.management'))).toBe(false)
    await ctx.close()
  })

  test('the public link viewer ignores the signal', async ({ browser }) => {
    const ctx = await freshSession(browser, 'e2e_owner')
    const [a, viewer] = [await ctx.newPage(), await ctx.newPage()]
    await viewer.goto(seed.links.open.path)
    await expect(viewer.getByRole('heading').first()).toBeVisible({ timeout: 20_000 })
    await signOutIn(a)
    await viewer.waitForTimeout(1000)
    await expect(screen(viewer)).toHaveCount(0)
    await ctx.close()
  })
})
