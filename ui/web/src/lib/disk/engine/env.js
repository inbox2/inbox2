// What this browser can do for the exact-view engine.
import { mobileLayoutNow } from '../../../hooks/useIsPhone'
import { engineSupport } from './logic'
import { isTauri } from '../../tauri'

// Where the engine files live (see docs in scripts/disk-engine-pack.mjs). Same origin by default.
export const ENGINE_BASE = (import.meta.env.VITE_DISK_ENGINE_URL || '/disk-engine').replace(/\/+$/, '')

export function currentSupport() {
  const c = typeof navigator !== 'undefined' ? navigator.connection : null
  return engineSupport({
    // The engine runs in its own isolated window (client.js), so what matters is
    // whether this browser can open and talk to one. The desktop app opens no
    // such window; it needs the engine built in (not done).
    // The Disk service worker carries the file to the engine window (lib/disk/sw.js broker).
    isolated: typeof BroadcastChannel !== 'undefined' && !!navigator.locks && !!navigator.serviceWorker && !isTauri(),
    hasCaches: typeof caches !== 'undefined' && typeof DecompressionStream !== 'undefined',
    phone: mobileLayoutNow(),
    saveData: !!c?.saveData,
    effectiveType: c?.effectiveType,
  })
}

// "Always open Office files in exact view on this device" (asked once, after the first exact view).
const ALWAYS_KEY = 'inbox2_disk_exact_always'
const DECLINED_KEY = 'inbox2_disk_engine_declined'
const read = (k) => { try { return localStorage.getItem(k) } catch { return null } }
const write = (k, v) => { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v) } catch { /* storage blocked */ } }
export const exactAlways = () => read(ALWAYS_KEY) // 'yes' | 'no' | null (not asked)
export const setExactAlways = (v) => write(ALWAYS_KEY, v)
export const engineDeclined = () => read(DECLINED_KEY) === 'yes'
export const setEngineDeclined = (v) => write(DECLINED_KEY, v ? 'yes' : null)
