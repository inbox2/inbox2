// Single shared handle to the local SQLite database (Tauri desktop only).
//
// Memoized so every reader reuses one connection instead of re-opening the
// file on each call (the previous pattern, copy-pasted across ~15 sites).
// Returns null in the browser, where there is no local DB — callers guard with
// isTauri() or a falsy check. The in-flight promise is cached so concurrent
// callers share one load; a failed load resets so the next call can retry.

import { isTauri } from './tauri.js';
import log from './log.js';
import { isDemoMode, scrub } from './demoData.js';

export const DB_NAME = 'sqlite:inbox2.db';

// At app boot the Rust engine opens and migrates the same DB file, so the very
// first `Database.load` from the UI can lose the race (busy/locked) and reject.
// Without a retry that one rejection painted an empty inbox until a folder
// switch or the 30s failsafe re-queried. Wait for the DB to become available
// (bounded) instead of giving up on the first miss.
const LOAD_ATTEMPTS = 12;
const LOAD_RETRY_MS = 250;

let dbPromise = null;

async function loadWithRetry() {
  const Database = (await import('@tauri-apps/plugin-sql')).default;
  let lastErr;
  for (let i = 0; i < LOAD_ATTEMPTS; i++) {
    try {
      return await Database.load(DB_NAME);
    } catch (e) {
      lastErr = e;
      if (i < LOAD_ATTEMPTS - 1) await new Promise(r => setTimeout(r, LOAD_RETRY_MS));
    }
  }
  throw lastErr;
}

// Demo mode reads through a stand-in: every SELECT comes back with fake people,
// subjects and bodies (lib/demoData.js). Writes pass straight through — the real
// rows are never touched.
let demoDb = null;
let demoTarget = null;

function demoHandle(db) {
  if (!db) return db;
  if (demoDb && demoTarget === db) return demoDb;
  demoTarget = db;
  demoDb = new Proxy(db, {
    get(target, prop) {
      if (prop === 'select') return async (...args) => scrub(await target.select(...args));
      const value = target[prop];
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return demoDb;
}

export async function getDb() {
  if (!isTauri()) return null;
  if (isDemoMode()) return demoHandle(await rawDb());
  return rawDb();
}

function rawDb() {
  if (!dbPromise) {
    dbPromise = loadWithRetry().catch((e) => {
      log.warn('DB', `Database.load failed after ${LOAD_ATTEMPTS} attempts: ${e?.message || e}`);
      dbPromise = null; // allow a retry on the next call
      return null;
    });
  }
  return dbPromise;
}
