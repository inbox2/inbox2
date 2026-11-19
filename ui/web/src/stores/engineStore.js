import { create } from 'zustand'

// The exact-view engine on this device (lib/disk/engine/install.js writes here).
//   status   'unknown' | 'none' | 'downloading' | 'verifying' | 'ready' | 'error'
//   loaded, total   download progress in bytes (compressed)
//   version, size   the installed engine's version and bytes on disk
export const ENGINE = { UNKNOWN: 'unknown', NONE: 'none', DOWNLOADING: 'downloading', VERIFYING: 'verifying', READY: 'ready', ERROR: 'error' }

const useEngineStore = create(() => ({
  status: ENGINE.UNKNOWN,
  loaded: 0,
  total: 0,
  version: null,
  size: 0,
  downloadSize: 0,
  error: null,
}))

export default useEngineStore
