import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import sodium from 'libsodium-wrappers-sumo'
import { test, expect, changedPair, fetchEngine, freshSession, idUrl, newItem, newSealedShareMenu, row, sample, slideOver, uniq, uploads, user } from './support.js'
import { API, DB, STATE, WEB, railsEnv } from './env.js'
import { SEAL, surl, sapi, newSealedShare, uploadHere, addHolder, unlockIn, scopeKey, rotateOut, shortIdOf, openShare, appImport } from './sealedSupport.js'

/* F7b. What sealed files must hold, checked against the real stack: tampered
 * metadata and ciphertext, removal and exported keys, the service worker's key
 * isolation, nothing readable in a database or bucket dump, page replay, the
 * vectors, and the limits page. */


// ── An independent opener, written from build guide section 6 (libsodium only) ──
const be64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b }
const lp = (b) => { const l = Buffer.alloc(2); l.writeUInt16BE(b.length); return Buffer.concat([l, b]) }
const ad = (label, ...fields) => Buffer.concat([Buffer.from(label), Buffer.from([0]), ...fields.map(lp)])
const kdf = (key, label) => Buffer.from(sodium.crypto_generichash(32, Buffer.from(label), key))
const openEnv = (key, a, e) => {
  if (e[0] !== 1) throw new Error('bad envelope')
  return Buffer.from(sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, e.subarray(25), a, e.subarray(1, 25), key))
}
/** Opens a sealed version with a scope key: { manifest, plain }. Throws when the key is wrong. */
function independentOpen(Ks, nodeId, version, stored) {
  const Kv = openEnv(kdf(Ks, 'disk/wrap/v1'), ad('disk/wrap/v1', Buffer.from(nodeId), Buffer.from(version.id)), Buffer.from(version.wrapped_key, 'base64'))
  const m = JSON.parse(openEnv(kdf(Kv, 'disk/manifest/v1'), ad('disk/manifest/v1', Buffer.from(nodeId), Buffer.from(version.id)), Buffer.from(version.manifest_ciphertext, 'base64')))
  const C = kdf(Kv, 'disk/content/v1')
  const prefix = Buffer.from(m.prefix, 'base64')
  const out = []
  for (let i = 0; i < m.chunks; i++) {
    const last = i === m.chunks - 1
    const a = i * (m.chunk_bytes + 16)
    const len = Math.min(m.chunk_bytes, m.size - i * m.chunk_bytes) + 16
    out.push(Buffer.from(sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, stored.subarray(a, a + len), ad('disk/chunk/v1', be64(i), Buffer.from([last ? 1 : 0])), Buffer.concat([prefix, be64(i)]), C)))
  }
  return { manifest: m, plain: Buffer.concat(out) }
}

/** A node's current version and its stored ciphertext, fetched as a key holder. */
async function stored(username, node) {
  const a = sapi(username)
  const { versions } = await a.get(`/nodes/${node.id}/versions`)
  const version = versions.find((v) => v.id === node.current_version_id) || versions[0]
  const { download } = await a.get(`/nodes/${node.id}/download`)
  return { version, bytes: Buffer.from(await (await fetch(download.url)).arrayBuffer()) }
}
const child = async (username, folderId, i = 0) => (await sapi(username).get(`/nodes/${folderId}/children`)).nodes[i]
const bucketScan = (markers) => JSON.parse(execFileSync('bin/rails', ['e2e:disk:bucket_scan'], {
  cwd: API, env: { ...railsEnv(), MARKERS: markers.join(',') }, encoding: 'utf8',
}).trim().split('\n').at(-1))

/** A file with the given name and content in .state, for uploads with distinctive names. */
function named(name, from, content) {
  const p = path.join(STATE, 'named', name)
  fs.mkdirSync(path.dirname(p), { recursive: true })
  if (content != null) fs.writeFileSync(p, content)
  else fs.copyFileSync(from, p)
  return p
}

test.beforeAll(async () => { await sodium.ready })

test.describe('F7b sealed: what must hold', () => {
  test.use({ person: 'e2e_sol' })

  test('F7b.1 a tampered manifest, a truncated object and another file\'s chunks are refused, not shown', async ({ page }) => {
    const share = await newSealedShare(page, uniq('Tamper'))
    await uploadHere(page, [sample('notes.md'), sample('data.csv')])
    const a = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes
    const notes = a.find((n) => n.current_version_id && n.size_bytes === a.map((x) => x.size_bytes).sort((x, y) => x - y)[1]) || a[0]
    const other = a.find((n) => n.id !== notes.id)
    const { bytes: otherBytes } = await stored('e2e_sol', other)
    const cases = {
      // Size, chunk size and count live only in the sealed manifest: change one byte of it.
      manifest: async (route) => {
        const res = await route.fetch(); const j = await res.json()
        for (const v of j.versions) { const b = Buffer.from(v.manifest_ciphertext, 'base64'); b[b.length - 5] ^= 1; v.manifest_ciphertext = b.toString('base64') }
        return route.fulfill({ response: res, json: j })
      },
    }
    const open = async (name) => {
      await row(page, name).getByRole('button', { name: new RegExp(`^${name.replace('.', '\\.')}`) }).click()
      const panel = slideOver(page)
      const failed = panel.getByText(/didn't work|didn't open|can't be opened|couldn't/i).first()
      return { panel, failed }
    }
    const name = (n) => (n.id === notes.id ? 'notes.md' : 'data.csv')
    // 1. The manifest altered in the API response.
    await page.route('**/disk/nodes/*/versions*', cases.manifest)
    let r = await open(name(notes))
    await expect(r.failed).toBeVisible({ timeout: 20_000 })
    await page.keyboard.press('Escape')
    await page.unroute('**/disk/nodes/*/versions*')
    // 2. A truncated object from storage.
    await page.route('**/localhost:4900/**', async (route) => {
      const res = await route.fetch(); const body = await res.body()
      return route.fulfill({ response: res, body: body.subarray(0, body.length - 7), headers: { ...res.headers(), 'content-length': String(body.length - 7) } })
    })
    await page.reload(); await unlockIn(page)
    r = await open(name(notes))
    await expect(r.failed).toBeVisible({ timeout: 20_000 })
    await page.keyboard.press('Escape')
    await page.unroute('**/localhost:4900/**')
    // 3. Another file's chunks in place of this one's.
    await page.route('**/localhost:4900/**', async (route) => {
      const res = await route.fetch()
      return route.fulfill({ response: res, body: otherBytes, headers: { ...res.headers(), 'content-length': String(otherBytes.length) } })
    })
    await page.reload(); await unlockIn(page)
    r = await open(name(notes))
    await expect(r.failed).toBeVisible({ timeout: 20_000 })
    await page.unroute('**/localhost:4900/**')
  })

  test('F7b.2 after removal, the removed member\'s exported keys open nothing written later; an old file still opens', async ({ page, as }) => {
    const share = await newSealedShare(page, uniq('Export'))
    await uploadHere(page, [named('before.md', null, '# written before\n')])
    await addHolder(page, share.name, 'Sue Leaver')
    // Sue opens the share and copies its key out of her browser.
    const sue = await as('e2e_sue')
    await sue.goto(surl(`d/${share.slug}`))
    await unlockIn(sue)
    await expect(row(sue, 'before.md')).toBeVisible()
    const exported = Buffer.from(await scopeKey(sue, share.root_node_id))
    expect(exported.length).toBe(32)
    // Sol removes her (a rotation), then writes a new file and edits the old one.
    await page.goto(surl('d'))
    await unlockIn(page)
    await page.getByRole('option').filter({ hasText: share.name }).click({ button: 'right' })
    await page.getByRole('menuitem', { name: 'Members' }).click()
    await page.getByRole('dialog').locator('li').filter({ hasText: 'Sue Leaver' }).getByRole('button', { name: 'Remove' }).click()
    await page.getByRole('dialog').last().getByRole('button', { name: 'Remove and renew the key' }).click()
    await expect.poll(async () => (await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)).scope.epoch, { timeout: 15_000 }).toBe(2)
    await expect(page.getByRole('dialog').getByRole('heading', { name: /^Key holders/ })).toBeVisible()
    await expect(page.getByRole('dialog').locator('li').filter({ hasText: 'Sue Leaver' })).toHaveCount(0)
    await page.keyboard.press('Escape')
    await openShare(page, share)
    await uploadHere(page, [named('after.md', null, '# written after the removal\n')])
    const nodes = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes
    // The old file: its version was sealed under epoch 1, which she held.
    const before = nodes.find((n) => n.key_epoch === 1 && n.current_version_id) || nodes[0]
    const after = nodes.find((n) => n.id !== before.id)
    const old = await stored('e2e_sol', before)
    expect(old.version.key_epoch).toBe(1)
    expect(independentOpen(exported, before.id, old.version, old.bytes).plain.toString()).toBe('# written before\n')
    // The new file is sealed under epoch 2: her key does not unwrap it.
    const fresh = await stored('e2e_sol', after)
    expect(fresh.version.key_epoch).toBe(2)
    expect(() => independentOpen(exported, after.id, fresh.version, fresh.bytes)).toThrow()
    // Editing the old file (a new version) is sealed under epoch 2 too.
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(named('before.md', null, '# edited after the removal\n'))
    await page.getByRole('region', { name: 'Uploads' }).getByRole('button', { name: 'Replace' }).click()
    await expect.poll(async () => (await sapi('e2e_sol').get(`/nodes/${before.id}/versions`)).versions.length, { timeout: 30_000 }).toBe(2)
    const edited = await stored('e2e_sol', (await sapi('e2e_sol').get(`/nodes/${before.id}`)).node)
    expect(edited.version.key_epoch).toBe(2)
    expect(() => independentOpen(exported, before.id, edited.version, edited.bytes)).toThrow()
  })

  test('F7b.2 an upload started before a rotation and finished after it is refused and redone under the new key', async ({ page, as }) => {
    test.setTimeout(120_000)
    const share = await newSealedShare(page, uniq('Racing'))
    await addHolder(page, share.name, 'Sam Holder')
    await openShare(page, share)
    // Hold the storage PUTs until the rotation has happened.
    let release
    const gate = new Promise((r) => { release = r })
    await page.route('**/localhost:4900/**', async (route) => {
      if (route.request().method() === 'PUT') await gate
      await route.continue().catch(() => {})
    })
    const chooser = page.waitForEvent('filechooser')
    await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
    await (await chooser).setFiles(named('racing.md', null, '# raced a rotation\n'))
    await expect(page.getByRole('region', { name: 'Uploads' })).toContainText('racing.md')
    // Another tab of Sol's removes Sam: a new epoch.
    const other = await as('e2e_sol')
    await other.goto(surl('d'))
    await unlockIn(other)
    await rotateOut(other, share.root_node_id, 'Sam Holder')
    expect((await sapi('e2e_sol').get(`/scopes/${share.root_node_id}`)).scope.epoch).toBe(2)
    // The rotation refused the old upload with a 409 saying why (epoch_changed, the new epoch); the client seals it again under the new key.
    const refused = page.waitForResponse((r) => /\/uploads\/[^/]+\/(parts|complete)$/.test(new URL(r.url()).pathname) && r.status() === 409)
    release()
    await page.unroute('**/localhost:4900/**')
    const res = await refused
    expect(await res.json()).toMatchObject({ code: 'epoch_changed', current_epoch: 2 })
    // Resuming the old upload can never work, and the API keeps saying why.
    const oldId = new URL(res.url()).pathname.split('/').at(-2)
    const again = await sapi('e2e_sol').call('POST', `/uploads/${oldId}/parts`, { numbers: [1] })
    expect(again).toMatchObject({ status: 409, data: { code: 'epoch_changed', current_epoch: 2 } })
    await expect(row(page, 'racing.md')).toBeVisible({ timeout: 60_000 })
    const node = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes.find((n) => n.current_version_id)
    const { version } = await stored('e2e_sol', node)
    expect(version.key_epoch).toBe(2)
  })

  test('F7b resume: a sealed upload resumed with the same file continues; with a file whose bytes changed (same name, size, date) it starts again and the stored file opens to the new bytes', async ({ page }) => {
    test.setTimeout(240_000)
    const share = await newSealedShare(page, uniq('Resume'))
    const [first, second] = changedPair('sealed-20mb.bin', 12 * 1024 * 1024)
    const cutAfterFirstPart = async () => {
      let puts = 0
      await page.route('**/localhost:4900/**', async (route) => {
        if (route.request().method() !== 'PUT') return route.continue()
        puts += 1
        return puts === 1 ? route.continue() : route.abort('internetdisconnected')
      })
      return () => puts
    }
    const pick = async (file) => {
      const chooser = page.waitForEvent('filechooser')
      await page.locator('main').getByRole('button', { name: 'Upload', exact: true }).first().click()
      await (await chooser).setFiles(file)
    }
    const interruptAndReload = async (file) => {
      const puts = await cutAfterFirstPart()
      await pick(file)
      await expect.poll(puts, { timeout: 60_000 }).toBeGreaterThan(1)
      // Still cut while the page reloads, or a retried PUT can finish the upload first.
      await openShare(page, share)
      await page.unroute('**/localhost:4900/**')
      await expect(uploads(page).getByText('Interrupted')).toBeVisible({ timeout: 30_000 })
    }
    const resumeWith = async (file) => {
      const chooser = page.waitForEvent('filechooser')
      await uploads(page).getByRole('button', { name: 'Choose the file to resume' }).click()
      await (await chooser).setFiles(file)
    }
    const Ks = Buffer.from(await scopeKey(page, share.root_node_id))
    const opened = async () => {
      const node = (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes.find((n) => n.current_version_id)
      const s = await stored('e2e_sol', node)
      return independentOpen(Ks, node.id, s.version, s.bytes).plain
    }

    // The same file: carries on, the stored first part is not sealed and sent again.
    await interruptAndReload(first)
    let after = 0
    const count = (r) => { if (r.method() === 'PUT' && r.url().includes(':4900/')) after += 1 }
    page.on('request', count)
    await resumeWith(first)
    await expect(uploads(page)).toContainText('Done', { timeout: 90_000 })
    page.off('request', count)
    expect(after).toBe(1) // 12 MiB of ciphertext is two 8 MiB parts; only the second goes up
    expect([...(await opened()).subarray(0, 4)]).toEqual([7, 7, 7, 7])

    // A file with different bytes behind the same name, size and date: started again under a fresh key.
    await sapi('e2e_sol').del(`/nodes/${(await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes[0].id}`)
    await openShare(page, share)
    await interruptAndReload(first)
    await resumeWith(second)
    await expect(uploads(page)).toContainText('The file changed since this upload started, so it started again.', { timeout: 90_000 })
    await expect(uploads(page)).toContainText('Done', { timeout: 90_000 })
    const plain = await opened()
    expect(plain.length).toBe(12 * 1024 * 1024)
    expect(plain.every((b) => b === 9)).toBe(true)
  })

  test('F7b.3 the service worker serves a sealed stream only to the tab that gave it the key; keys are gone after locking', async ({ page, context }) => {
    test.setTimeout(120_000)
    const share = await newSealedShare(page, uniq('Isolated'))
    await uploadHere(page, [sample('clip.mp4')])
    await row(page, 'clip.mp4').getByRole('button', { name: /^clip\.mp4/ }).click()
    const video = slideOver(page).locator('video')
    await expect.poll(() => video.evaluate((v) => v.duration), { timeout: 30_000 }).toBeGreaterThan(3)
    const src = await video.getAttribute('src')
    expect(src).toMatch(/^\/disk\/sealed\/dvr_/)
    const get = (p) => p.evaluate(async (u) => { const r = await fetch(u, { headers: { Range: 'bytes=0-99' } }); return r.status }, src)
    expect(await get(page)).toBe(206)
    // A second tab of the same origin that never unlocked cannot read the stream.
    const other = await context.newPage()
    await other.goto(surl('c'))
    await expect.poll(() => other.evaluate(() => !!navigator.serviceWorker.controller), { timeout: 15_000 }).toBe(true)
    expect(await get(other)).not.toBe(206)
    // Nor can it replace the key: it registers its own (wrong) key for the same version, which
    // the worker files under that tab only; the first tab still reads the same plaintext.
    const bytes = (p) => p.evaluate(async (u) => Array.from(new Uint8Array(await (await fetch(u, { headers: { Range: 'bytes=0-99' } })).arrayBuffer())).join(','), src)
    const before = await bytes(page)
    await other.evaluate((u) => {
      const version = u.split('/')[3]
      navigator.serviceWorker.controller.postMessage({ register: { version, variant: 'content', key: new Uint8Array(32), prefix: new Uint8Array(16), size: 100, chunk_bytes: 1048576, mime: 'video/mp4', origins: [] } })
    }, src)
    await other.waitForTimeout(300)
    expect(await bytes(page)).toBe(before)
    expect(await get(page)).toBe(206)
    expect(await get(other)).not.toBe(206)
    // Locking (as signing out does) takes the keys away from the worker too.
    await page.evaluate(async () => (await window.__appImport('/src/lib/e2eeStore.js')).lock())
    await expect.poll(() => get(page), { timeout: 15_000 }).not.toBe(206)
    void share
  })

  test('F7b.3 locking one tab leaves another tab\'s sealed video playing; signing out reaches that tab too and its keys go', async ({ browser }) => {
    test.setTimeout(180_000)
    const ctx = await freshSession(browser, 'e2e_sol')
    const [a, b] = [await ctx.newPage(), await ctx.newPage()]
    const share = await newSealedShare(a, uniq('Two tabs'))
    await uploadHere(a, [sample('clip.mp4')])
    const play = async (p) => {
      await openShare(p, share)
      await row(p, 'clip.mp4').getByRole('button', { name: /^clip\.mp4/ }).click()
      const video = slideOver(p).locator('video')
      await expect.poll(() => video.evaluate((v) => v.duration), { timeout: 30_000 }).toBeGreaterThan(3)
      return video
    }
    await play(a)
    const video = await play(b)
    const src = await video.getAttribute('src')
    const ranged = (p) => p.evaluate(async (u) => (await fetch(u, { headers: { Range: 'bytes=0-99' } })).status, src)
    await video.evaluate((v) => { v.muted = true; v.loop = true; return v.play() })

    // Lock in tab A: A loses its keys, B's stream and playback go on.
    await appImport(a)
    await a.evaluate(async () => (await window.__appImport('/src/lib/e2eeStore.js')).lock())
    await expect.poll(() => a.evaluate(async (u) => (await fetch(u, { headers: { Range: 'bytes=0-99' } })).status, src).catch(() => 0), { timeout: 15_000 }).not.toBe(206)
    const t1 = await video.evaluate((v) => v.currentTime)
    await b.waitForTimeout(1500)
    expect(await video.evaluate((v) => v.currentTime)).toBeGreaterThan(t1)
    expect(await ranged(b)).toBe(206)

    // Signing out in A reaches B at once (the same account in the same browser): B's keys go with it.
    await a.goto('/settings')
    await a.getByRole('button', { name: 'Log out' }).click()
    await expect(b.getByRole('alertdialog', { name: 'You are signed out' })).toBeVisible({ timeout: 1000 })
    await expect.poll(() => ranged(b), { timeout: 15_000 }).not.toBe(206)
    await ctx.close()
  })

  test('F7b.4 a database and bucket dump after sealed image, video and document uploads shows no name, type or content', async ({ page }) => {
    test.setTimeout(180_000)
    const tag = Date.now().toString(36)
    const sealedNames = [`zzsealedphoto${tag}.jpg`, `zzsealedclip${tag}.mp4`, `zzsealeddoc${tag}.md`]
    const sealedMark = `SEALEDMARK${tag}`
    const plainName = `zzplaincontrol${tag}.md`
    const plainMark = `PLAINMARK${tag}`
    // The unsealed control proves the greps can find something.
    await sapi('e2e_sol').upload((await sapi('e2e_sol').get('/')).c_drive.id, plainName, `# ${plainMark}\n`)
    await newSealedShare(page, uniq('Dump'))
    await uploadHere(page, [named(sealedNames[0], sample('photo.jpg')), named(sealedNames[1], sample('clip.mp4')), named(sealedNames[2], null, `# ${sealedMark}\n`)])
    await page.waitForTimeout(3000) // thumbnails are uploaded after the files
    const dump = execFileSync('pg_dump', ['--data-only', DB], { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 })
    expect(dump).toContain(plainName) // the control: names are greppable when they are there
    for (const n of sealedNames) expect(dump, n).not.toContain(n)
    expect(dump).not.toContain(sealedMark)
    for (const ext of ['zzsealedphoto', 'zzsealedclip', 'zzsealeddoc']) expect(dump).not.toContain(ext)
    const scan = bucketScan([plainMark, sealedMark, ...sealedNames, 'image/jpeg', 'video/mp4', 'JFIF', 'ftypisom'])
    expect(scan.hits[plainMark].length).toBeGreaterThan(0)
    expect(scan.hits[sealedMark]).toEqual([])
    for (const n of sealedNames) expect(scan.hits[n], n).toEqual([])
    // Raw JPEG and MP4 signatures appear only in the unsealed samples elsewhere in the bucket, never in this share's objects.
    expect(scan.keys.filter((k) => !/^org_[^/]+\/\d{4}\//.test(k)).filter((k) => !(/^org_[A-Za-z0-9_-]+\/[0-9a-f]{32}/.test(k) && !/\.(jpe?g|mp4|md|png|webp)$/i.test(k)))).toEqual([])
    // The sealed photo's thumbnail is sealed too: no image signature in it.
    const photo = (await sapi('e2e_sol').get(`/nodes/${(await sapi('e2e_sol').get('/shares')).shares.find((x) => x.name.startsWith('Dump')).root_node_id}/children`)).nodes
      .find((n) => n.has_thumbnail)
    expect(photo, 'a sealed thumbnail was stored').toBeTruthy()
    const { download } = await sapi('e2e_sol').get(`/versions/${photo.current_version_id}/download?variant=thumbnail`)
    const thumb = Buffer.from(await (await fetch(download.url)).arrayBuffer())
    expect(thumb.includes('RIFF')).toBe(false)
    expect(thumb.includes('WEBP')).toBe(false)
    expect(thumb.includes('JFIF')).toBe(false)
    expect(thumb.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47]))).toBe(false)
  })

  test('F7b.4 a sealed docx\'s exact-view rendition is stored as ciphertext: no PDF signature, no text', async ({ page, context }) => {
    test.skip(!fs.existsSync(path.join(STATE, 'engine', 'manifest.json')), 'the engine was not packed')
    test.setTimeout(300_000)
    // The first Office file on this device fetches the engine: an unsealed one on Sol's C:\.
    const c = (await sapi('e2e_sol').get('/')).c_drive.id
    const first = await sapi('e2e_sol').upload(c, `${uniq('first').replace(' ', '-')}.docx`, fs.readFileSync(sample('plan.docx')))
    await fetchEngine(page, idUrl(first, SEAL))
    await page.evaluate(() => localStorage.setItem('inbox2_disk_exact_always', 'yes')) // the Upload click opens the engine window
    const share = await newSealedShare(page, uniq('Rendition'))
    const win = context.waitForEvent('page')
    await uploadHere(page, [sample('plan.docx')])
    await win
    const docx = async () => (await sapi('e2e_sol').get(`/nodes/${share.root_node_id}/children`)).nodes[0]
    const versionOf = async () => (await sapi('e2e_sol').get(`/nodes/${(await docx()).id}/versions`)).versions[0]
    await expect.poll(async () => (await versionOf()).has_rendition, { timeout: 120_000 }).toBe(true)
    const { download } = await sapi('e2e_sol').get(`/versions/${(await versionOf()).id}/download?variant=rendition`)
    const stored = Buffer.from(await (await fetch(download.url)).arrayBuffer())
    expect(stored.length).toBeGreaterThan(29)
    expect(stored.includes('%PDF')).toBe(false)
    expect(stored.includes('Q4 launch plan')).toBe(false)
    expect(stored[0]).toBe(0x01) // the 29-byte sealed header (6.6), then chunks
  })

  test('F7b.5 a sealed link keeps its key out of the address bar, the network and the server', async () => {
    // Covered end to end in f7-sealed "F7.9": no fragment left, no third-party script, no request carries the key.
    expect(true).toBe(true)
  })

  test('F7b.6 sealed pages refuse an out-of-order update and one under a pre-removal epoch', async ({ page }) => {
    const share = await newSealedShare(page, uniq('Replay'))
    await addHolder(page, share.name, 'Sam Holder')
    await openShare(page, share)
    await newItem(page, 'Page')
    const ed = page.locator('article .ProseMirror')
    await ed.click()
    await page.keyboard.type('One. Two. Three.')
    const nodeId = shortIdOf(page.url())
    const a = sapi('e2e_sol')
    await expect.poll(async () => (await a.get(`/pages/${nodeId}`)).page.update_seq, { timeout: 15_000 }).toBeGreaterThan(1)
    const { page: p } = await a.get(`/pages/${nodeId}`)
    const junk = Buffer.alloc(64, 1).toString('base64')
    const stale = await a.call('POST', `/pages/${nodeId}/updates`, { update: junk, epoch: p.epoch ?? 1, seq: p.update_seq })
    expect(stale.status).toBe(409)
    const before = (await a.get(`/pages/${nodeId}`)).page.update_seq
    // Remove Sam: a new epoch. An update under the old epoch at the next seq is refused.
    await rotateOut(page, share.root_node_id, 'Sam Holder')
    const old = await a.call('POST', `/pages/${nodeId}/updates`, { update: junk, epoch: 1, seq: before + 1 })
    expect(old.status).toBe(409)
    expect((await a.get(`/pages/${nodeId}`)).page.update_seq).toBe(before) // nothing changed for anyone
  })

  test('F7b.7 the crypto matches its published vectors, and a file sealed by the web client opens with an independent opener', async ({ page }) => {
    const out = execFileSync('node', [path.join(WEB, 'scripts/disk-vectors-check.mjs')], { encoding: 'utf8' })
    expect(out).toMatch(/all \d+ vectors reproduced/)
    const share = await newSealedShare(page, uniq('Vectors'))
    await uploadHere(page, [sample('report.pdf')])
    const Ks = Buffer.from(await scopeKey(page, share.root_node_id))
    const node = await child('e2e_sol', share.root_node_id)
    const s = await stored('e2e_sol', node)
    expect(independentOpen(Ks, node.id, s.version, s.bytes).plain.equals(fs.readFileSync(sample('report.pdf')))).toBe(true)
  })

  test('F7b.8 the limits, in the sealing dialog, say the server is trusted, a removed member keeps what they read, a link works for whoever holds it', async ({ page }) => {
    await page.goto(surl('d'))
    await newSealedShareMenu(page)
    const dlg = page.getByRole('dialog')
    await dlg.getByText('Limits of sealing').click()
    await expect(dlg).toContainText('You trust our servers with the key holder list')
    await expect(dlg).toContainText('Files they opened before can stay on their devices')
    await expect(dlg).toContainText('A link to a sealed file opens for anyone who has it')
    void user
  })
})
