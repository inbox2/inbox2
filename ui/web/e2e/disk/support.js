// Shared helpers for the Disk specs: the seed, signed-in pages per person, a
// small API client (the same endpoints the web uses, with a person's bearer)
// and the selectors the specs share.
import { test as base, expect } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { API, BASE, RAILS, SAMPLES, SEED, STATE, railsEnv } from './env.js'

export { expect }
export const seed = JSON.parse(fs.readFileSync(SEED, 'utf8'))
export const ORG = 'e2e-disk'
export const auth = (username) => path.join(STATE, 'auth', `${username}.json`)
export const sample = (name) => path.join(SAMPLES, name)
export const node = (key) => seed.nodes[key]
export const share = (name) => seed.shares[name]
export const user = (username) => seed.users[username]
export const uniq = (prefix) => `${prefix} ${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`

// URLs (lib/disk/model.js): the id is the authority, the name part is decoration.
// Disk URLs carry no org since 2026-10-04: Disk is on one org at a time (the person's own,
// for everyone the seed makes); another org is asked for with ?org=, which the app drops.
export const diskUrl = (where = '', org = ORG) => `/disk${where ? `/${where}` : ''}${org === ORG ? '' : `?org=${org}`}`
export const idUrl = (n, org = ORG) => diskUrl(`shared/${encodeURIComponent(n.name || 'item')}-${n.short_id}`, org)
export const shareUrl = (name, org = ORG) => diskUrl(`d/${share(name).slug}`, org)

/** A test whose default page is signed in as `username` (test.use({ person })). */
// Dev serves hundreds of modules: keep every resource timing entry, so sealedSupport's
// appImport can find the URL (with Vite's ?t=) the app loaded a module from.
const BIG_TIMING = () => performance.setResourceTimingBufferSize(20000)

export const test = base.extend({
  person: ['e2e_owner', { option: true }],
  storageState: async ({ person }, provide) => provide(auth(person)),
  context: async ({ context }, provide) => { await context.addInitScript(BIG_TIMING); await provide(context) },
  /** Another signed-in page as someone else: const p = await as('e2e_ana'). */
  as: async ({ browser }, provide) => {
    const contexts = []
    await provide(async (username, options = {}) => {
      const ctx = await browser.newContext({ storageState: auth(username), ...options })
      await ctx.addInitScript(BIG_TIMING)
      contexts.push(ctx)
      return ctx.newPage()
    })
    for (const c of contexts) await c.close()
  },
})

// ── selectors ──
export const rows = (page) => page.locator('tbody tr')
// A row's name button also says "Starred" or "sealed" (sometimes with no space); match the name at its start.
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
export const named = (name) => new RegExp(`^${esc(name)}(\\s|$|sealed)`)
export const row = (page, name) => rows(page).filter({ has: page.getByRole('button', { name: named(name) }) })
export const tile = (page, name) => page.getByRole('option').filter({ has: page.getByRole('button', { name: named(name) }) })
export const crumbs = (page) => page.getByRole('navigation', { name: 'Path' })
export const slideOver = (page) => page.getByRole('dialog').filter({ has: page.getByRole('button', { name: 'Close' }) })
export const uploads = (page) => page.getByRole('region', { name: 'Uploads' })
export const toast = (page) => page.locator('[role="status"][aria-live="polite"]').last()

/** Waits for the folder listing (a table, the empty card, or tiles) to have landed. */
export async function listed(page) {
  await expect(page.locator('[aria-busy="false"]').first()).toBeVisible()
}

/** Opens a folder page and waits for its title. */
export async function openFolder(page, url, title) {
  await page.goto(url)
  await expect(page.locator('main h1')).toHaveText(title) // the h1 also holds the actions menu and the star
}

// A split button's arrow, then a plain-button item in its portal menu (DropdownMenu). The list can
// remount while it lands, which drops an open menu, so reopen until the item shows.
async function fromMenu(page, arrow, item) {
  await expect(async () => {
    if (!(await item.isVisible())) await arrow.click({ timeout: 3000 })
    await expect(item).toBeVisible({ timeout: 2000 })
  }).toPass({ timeout: 20_000 })
  await item.click()
}

/** The "New" split button's menu: 'Folder', 'Page' or 'Sealed folder'. */
export const newItem = (page, what) => fromMenu(page, page.locator('main').getByRole('button', { name: 'More to make' }), page.getByRole('button', { name: what, exact: true }))
/** The split button's arrow: gone for a viewer or a selection, there for an editor. */
export const newMenu = (page) => page.locator('main').getByRole('button', { name: 'More to make' })

/** The "New sealed share" item of the shares page's split button. */
export const newSealedShareMenu = (page) => fromMenu(page, page.getByRole('button', { name: 'More kinds of share' }), page.getByRole('button', { name: 'New sealed share' }))

/** Opens an Office file (first file on this device, so the engine downloads) and waits for the engine. */
export async function fetchEngine(page, url) {
  await page.goto(url)
  await expect(page.getByRole('button', { name: 'Show exact view' })).toBeVisible({ timeout: 180_000 })
  await page.keyboard.press('Escape')
}

// ── API (as a person, straight to the e2e Rails) ──
export function api(username, org = user(username).org) {
  const token = user(username).token
  const call = async (method, p, body) => {
    const res = await fetch(`${RAILS}/api/v1${/^\/(orgs|disk|account|notifications)\b/.test(p) ? '' : `/orgs/${org}/disk`}${p}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    let data
    try { data = text ? JSON.parse(text) : null } catch { data = text }
    return { status: res.status, data }
  }
  const ok = async (method, p, body) => {
    const r = await call(method, p, body)
    if (r.status >= 400) throw new Error(`${method} ${p} -> ${r.status} ${JSON.stringify(r.data)}`)
    return r.data
  }
  return {
    call,
    get: (p) => ok('GET', p),
    post: (p, b = {}) => ok('POST', p, b),
    put: (p, b = {}) => ok('PUT', p, b),
    patch: (p, b = {}) => ok('PATCH', p, b),
    del: (p) => ok('DELETE', p),
    folder: async (parentId, name) => (await ok('POST', '/nodes', { parent_id: parentId, name, kind: 'folder' })).node,
    page: async (parentId, name) => (await ok('POST', '/nodes', { parent_id: parentId, name, kind: 'page' })).node,
    /** The upload protocol (build guide section 8) end to end: reserve, parts, PUT to storage, complete. */
    upload: async (parentId, name, bytes, extra = {}) => {
      const buf = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes)
      const { upload } = await ok('POST', '/uploads', { parent_id: parentId, name, size_bytes: buf.length, ...extra })
      if (buf.length) {
        const numbers = Array.from({ length: upload.part_count }, (_, i) => i + 1)
        const parts = []
        for (let i = 0; i < numbers.length; i += 100) parts.push(...(await ok('POST', `/uploads/${upload.id}/parts`, { numbers: numbers.slice(i, i + 100) })).parts)
        for (const p of parts) {
          const chunk = buf.subarray((p.number - 1) * upload.part_bytes, p.number * upload.part_bytes)
          const r = await fetch(p.url, { method: 'PUT', body: chunk })
          if (!r.ok) throw new Error(`part ${p.number}: ${r.status}`)
        }
      }
      return (await ok('POST', `/uploads/${upload.id}/complete`)).node
    },
  }
}

/** A fresh folder for one test, so tests never depend on each other's leftovers. */
export async function scratch(username, parentId, prefix = 'e2e') {
  return api(username).folder(parentId, uniq(prefix))
}

export const short = (n) => (n.short_id || n.id).slice(-21)
export const folderUrl = (n) => idUrl({ name: n.name, short_id: short(n) })

/** Two files with the same name, size and modification time but different bytes
 * (fill 7, then 9), for the resume-with-a-changed-file tests. Returns [first, second] paths. */
export function changedPair(name, size = 20 * 1024 * 1024) {
  const when = new Date('2026-09-01T10:00:00Z')
  return [7, 9].map((fill) => {
    const dir = path.join(STATE, `resume-${fill}`)
    fs.mkdirSync(dir, { recursive: true })
    const p = path.join(dir, name)
    if (!fs.existsSync(p)) fs.writeFileSync(p, Buffer.alloc(size, fill))
    fs.utimesSync(p, when, when)
    return p
  })
}

export const TOKEN_KEY = 'inbox2_cloud_auth_token'
/** A browser context signed in with a new session of its own (minted by
 * `bin/rails e2e:disk:session`, not POST /auth/login, which allows five a
 * minute per address), so signing out there ends that session only. */
export async function freshSession(browser, username) {
  const token = execFileSync('bin/rails', ['e2e:disk:session'], { cwd: API, env: { ...railsEnv(), USER_NAME: username } }).toString().trim().split('\n').pop()
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [{ origin: BASE, localStorage: [{ name: TOKEN_KEY, value: token }] }] } })
  await ctx.addInitScript(BIG_TIMING)
  return ctx
}
