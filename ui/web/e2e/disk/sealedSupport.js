// Helpers for the sealed specs (f7-sealed, f7b-sealed-limits, screens): org
// e2e-seal, whose people get identity keys from the real client in global-setup.js.
import { expect, api, diskUrl, newSealedShareMenu, row, seed, tile } from './support.js'

export const SEAL = 'e2e-seal'
export const surl = (where) => diskUrl(where, SEAL)
export const sapi = (u) => api(u, SEAL)

/** Unlocks the identity key through the UI prompt a sealed screen shows. */
export async function unlockPrompt(page) {
  const field = page.getByLabel('Your inbox2 password').first()
  await field.fill(seed.password)
  await page.getByRole('button', { name: 'Unlock' }).first().click()
  await expect(field).toHaveCount(0)
}

/** Unlocks with the real client function (lib/e2eeStore.js unlock), for set-up steps. */
export async function unlockIn(page) {
  await appImport(page)
  await page.evaluate(async (pw) => (await window.__appImport('/src/lib/e2eeStore.js')).unlock(pw), seed.password)
}

/** A new sealed share made through the UI by the signed-in person, opened. Returns its API record. */
export async function newSealedShare(page, name, username = 'e2e_sol') {
  await page.goto(surl('d'))
  await expect(page.locator('main h1')).toHaveText('Shared disk')
  await unlockIn(page)
  await newSealedShareMenu(page)
  const dlg = page.getByRole('dialog')
  await dlg.getByLabel('Name').fill(name)
  const ack = dlg.getByText(/If I lose my password and recovery phrase/)
  if (await ack.isVisible().catch(() => false)) await ack.click()
  await dlg.getByRole('button', { name: 'Create sealed share' }).click()
  await expect(page.locator('main h1')).toHaveText(name)
  const { shares } = await sapi(username).get('/shares')
  const share = shares.find((s) => s.name === name)
  await waitOpen(page, share.root_node_id)
  return share
}

export async function uploadHere(page, files) {
  const chooser = page.waitForEvent('filechooser')
  await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
  await (await chooser).setFiles(files)
  for (const f of files) await expect(row(page, f.split('/').pop())).toBeVisible({ timeout: 60_000 })
}

/** Adds a key holder through the share's Key holders dialog. */
export async function addHolder(page, shareName, person, role = 'edit') {
  await page.goto(surl('d'))
  await unlockIn(page)
  await tile(page, shareName).click({ button: 'right' })
  await page.getByRole('menuitem', { name: 'Members' }).click()
  const dlg = page.getByRole('dialog')
  await expect(dlg.getByRole('heading', { name: `Key holders of ${shareName}` })).toBeVisible()
  await dlg.getByRole('combobox', { name: 'Person' }).selectOption({ label: person })
  await dlg.getByRole('combobox', { name: 'Role', exact: true }).selectOption(role)
  await dlg.getByRole('button', { name: 'Add' }).click()
  await expect(dlg.locator('li').filter({ hasText: person })).toBeVisible()
  await page.keyboard.press('Escape')
}

export const ORG_ID = () => seed.orgs[SEAL].id

// The app's own instance of a module: after a hot reload Vite serves it as /src/x.js?t=...,
// and a plain import('/src/x.js') would get a second, empty copy. Runs in the page.
const APP_IMPORT = `window.__appImport = (p) => {
  const hit = performance.getEntriesByType('resource').map((e) => e.name).filter((n) => new URL(n).pathname === p).at(-1)
  return import(hit || p)
}`
export const appImport = async (page) => { await page.evaluate(APP_IMPORT) }
/** The short id at the end of a Disk URL (it may contain - and _). */
export const shortIdOf = (url) => new URL(url).pathname.slice(-21)
/** Opens a sealed scope through the app's own store and returns its key bytes (what a holder could copy out of their browser). */
export const scopeKey = async (page, scopeId) => { await appImport(page); return page.evaluate(async ({ org, id }) => {
  const store = (await window.__appImport('/src/stores/sealedStore.js')).default
  const s = await store.getState().open(org, id)
  return s ? [...s.key] : null
}, { org: ORG_ID(), id: scopeId }) }
/** Removes a holder by name through the real client rotation (lib/disk/sealed.js rotateScope). */
export const rotateOut = async (page, scopeId, name) => { await appImport(page); return page.evaluate(async ({ org, id, name }) => {
  const store = (await window.__appImport('/src/stores/sealedStore.js')).default
  const scope = await store.getState().open(org, id)
  const lib = await window.__appImport('/src/lib/disk/sealed.js')
  await lib.rotateScope({ orgId: org, scope, remove: name ? [scope.holders.find((h) => h.name === name).id] : [] })
}, { org: ORG_ID(), id: scopeId, name }) }

/** Waits until the app's sealed store has this scope open (after unlocking). */
export async function waitOpen(page, scopeId) {
  await appImport(page)
  await expect.poll(() => page.evaluate(async ({ org, id }) => {
    const store = (await window.__appImport('/src/stores/sealedStore.js')).default
    return store.getState().scopes[`${org}/${id}`]?.status || 'none'
  }, { org: ORG_ID(), id: scopeId }), { timeout: 15_000 }).toBe('open')
}

/** Opens a sealed share's page, unlocked, with its key open. */
export async function openShare(page, share) {
  await page.goto(surl(`d/${share.slug}`))
  await unlockIn(page)
  await expect(page.locator('main h1')).toHaveText(share.name)
  await waitOpen(page, share.root_node_id)
}
