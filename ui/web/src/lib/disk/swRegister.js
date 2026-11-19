// Registers the Disk service worker (lib/disk/sw.js, served as /disk-sw.js) at
// scope "/" (6.11): a narrower scope never controls a tab that loaded on a mail
// URL, and Disk is entered by an in-app switch. The worker acts only on
// /disk/sealed/ and lets every other request through untouched. Disk's own pages
// live under /disk/ too since 2026-10-04 (no org in the path); none of them is
// /disk/sealed/ (lib/disk/model.js parses "sealed" as not found, and a sealed
// item's segment is sealed-<id> under c/, d/ or shared/). It is the app's
// only service worker; a second root-scope one would have to be merged into it.
// Kept apart from sealed.js so Disk can register it without loading libsodium.

/**
 * Registers with the storage origins from GET /disk settings.storage_origins.
 * With none it still registers: it also brokers exact-view conversions (it then
 * serves no sealed file, as no ciphertext origin is allowed).
 */
export function registerDiskWorker(origins) {
  if (typeof navigator === 'undefined' || !navigator.serviceWorker || !Array.isArray(origins)) return null
  return navigator.serviceWorker.register(`/disk-sw.js?storage=${encodeURIComponent(origins.join(','))}`, { scope: '/' }).catch(() => null)
}

/** The controlling worker, waiting for clients.claim() after a first registration (up to ms). */
export async function diskWorker(ms = 4000) {
  const sw = navigator.serviceWorker
  if (!sw) return null
  if (sw.controller) return sw.controller
  if (!(await sw.getRegistration('/'))) return null
  await Promise.race([new Promise((ok) => sw.addEventListener('controllerchange', ok, { once: true })), new Promise((ok) => setTimeout(ok, ms))])
  return sw.controller
}
