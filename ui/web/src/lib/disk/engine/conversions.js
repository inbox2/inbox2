// Office files this device already converted, kept per account (spec F5b):
// reopening shows exact view with no conversion, the cache stays under a cap
// by dropping the least recently used, and another account never sees them.
// Keyed by version id, so a new version converts again.
import { CONVERSION_CACHE_PREFIX, lruEvict, otherAccountCaches } from './logic'

export const CONVERSION_CAP = 300 * 1024 ** 2
const cacheName = (account) => `${CONVERSION_CACHE_PREFIX}${account}`
const indexKey = (account) => `inbox2_disk_conv_index_${account}`
const keyUrl = (versionId) => `/__disk-conv/${encodeURIComponent(versionId)}`
const has = () => typeof caches !== 'undefined'

function readIndex(account) {
  try { return JSON.parse(localStorage.getItem(indexKey(account)) || '{}') } catch { return {} }
}
function writeIndex(account, index) {
  try { localStorage.setItem(indexKey(account), JSON.stringify(index)) } catch { /* storage blocked */ }
}

/** A cached PDF for this version, or null. */
export async function getConversion(account, versionId) {
  if (!has() || !account || !versionId) return null
  const res = await (await caches.open(cacheName(account))).match(keyUrl(versionId))
  if (!res) return null
  const index = readIndex(account)
  if (index[versionId]) { index[versionId].at = Date.now(); writeIndex(account, index) }
  return res.blob()
}

export async function putConversion(account, versionId, pdf) {
  if (!has() || !account || !versionId) return
  const cache = await caches.open(cacheName(account))
  const index = readIndex(account)
  for (const key of lruEvict(index, CONVERSION_CAP, pdf.byteLength ?? pdf.size)) {
    await cache.delete(keyUrl(key))
    delete index[key]
  }
  await cache.put(keyUrl(versionId), new Response(pdf, { headers: { 'Content-Type': 'application/pdf' } }))
  index[versionId] = { bytes: pdf.byteLength ?? pdf.size, at: Date.now() }
  writeIndex(account, index)
}

/** Drops one conversion (the file went away or access ended). */
export async function forgetConversion(account, versionId) {
  if (!has() || !account) return
  await (await caches.open(cacheName(account))).delete(keyUrl(versionId))
  const index = readIndex(account)
  delete index[versionId]
  writeIndex(account, index)
}

export const conversionBytes = (account) => Object.values(readIndex(account)).reduce((s, v) => s + v.bytes, 0)

/** Removes conversions of every other account on this device. */
export async function dropOtherAccounts(account) {
  if (!has()) return
  for (const name of otherAccountCaches(await caches.keys(), account)) {
    await caches.delete(name)
    try { localStorage.removeItem(indexKey(name.slice(CONVERSION_CACHE_PREFIX.length))) } catch { /* storage blocked */ }
  }
}

/** Removes every account's conversions (sign-out, Settings › Clear). The engine itself stays. */
export async function clearAllConversions() {
  if (!has()) return
  await dropOtherAccounts('\u0000')
}
