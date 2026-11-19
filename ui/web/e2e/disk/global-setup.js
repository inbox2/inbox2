import { chromium } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'
import { BASE, RAILS, SEED, STATE } from './env.js'

/* Writes one Playwright storage state per seeded person (the seed minted their
 * sessions; the dev web build reads its bearer from localStorage), then warms
 * Vite so the first spec does not pay the cold compile inside its timeout. */
export default async function globalSetup() {
  if (!fs.existsSync(SEED)) throw new Error('No seed: run `yarn e2e:disk` (prepare.mjs seeds), not playwright on its own.')
  const seed = JSON.parse(fs.readFileSync(SEED, 'utf8'))
  const dir = path.join(STATE, 'auth')
  fs.mkdirSync(dir, { recursive: true })
  for (const [username, u] of Object.entries(seed.users)) {
    fs.writeFileSync(path.join(dir, `${username}.json`), JSON.stringify({
      cookies: [],
      origins: [{ origin: BASE, localStorage: [{ name: 'inbox2_cloud_auth_token', value: u.token }] }],
    }))
  }

  const browser = await chromium.launch()
  try {
    // Identity keys for the sealed org, made by the real client code in a real
    // browser (lib/e2eeStore.js setupIdentity: generate, wrap with the password,
    // upload), exactly as Settings does. Fresh database, so fresh keys every run.
    for (const username of seed.sealed_people || []) {
      // Re-runs against a reused database (E2E_DISK_REUSE): a person disabled by an earlier
      // run (the leaver test) has no session left; their key already exists, so skip them.
      const alive = await fetch(`${RAILS}/api/v1/account`, { headers: { Authorization: `Bearer ${seed.users[username].token}` } })
      if (!alive.ok) continue
      const ctx = await browser.newContext({ storageState: path.join(dir, `${username}.json`) })
      const page = await ctx.newPage()
      await page.goto(`${BASE}/disk/c`, { timeout: 180_000 })
      await page.getByRole('heading', { name: 'My disk' }).waitFor({ timeout: 180_000 })
      const status = await page.evaluate(async (pw) => {
        const m = await import('/src/lib/e2eeStore.js')
        if ((await m.refreshIdentity()) === 'none') await m.setupIdentity(pw)
        return m.refreshIdentity()
      }, seed.password)
      if (!['locked', 'unlocked'].includes(status)) throw new Error(`identity setup for ${username} ended ${status}`)
      await ctx.close()
    }

    const page = await browser.newPage({ storageState: path.join(dir, 'e2e_owner.json') })
    await page.goto(`${BASE}/disk/c`, { timeout: 180_000 })
    await page.getByRole('heading', { name: 'My disk' }).waitFor({ timeout: 180_000 })
    // The lazy chunks the specs open: the page editor, a preview, the console.
    await page.goto(`${BASE}/console/disk`, { timeout: 120_000 })
    await page.getByRole('heading', { name: 'Disk', level: 1 }).waitFor({ timeout: 120_000 })
  } finally {
    await browser.close()
  }
}
