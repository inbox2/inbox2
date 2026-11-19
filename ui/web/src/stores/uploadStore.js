import { create } from 'zustand'

// What the upload panel shows. The engine (lib/disk/upload.js) writes here.
//   items       one per file: { id, orgId, name, relativePath, size, loaded, state, error, parentId, uploadId, ... }
//   conflictAll a choice for every remaining name clash in this session ('keep_both' | 'replace' | 'skip'), or null
export const UPLOAD_STATE = {
  QUEUED: 'queued',
  RUNNING: 'running',
  PAUSED: 'paused',
  CONFLICT: 'conflict',
  DONE: 'done',
  ERROR: 'error',
  CANCELLED: 'cancelled',
  // Found in IndexedDB after a reload: the upload exists, the File does not until it is picked again.
  INTERRUPTED: 'interrupted',
}

const useUploadStore = create((set) => ({
  items: [],
  conflictAll: null,
  // An Office file went up from a device that could add exact view but has not: offer the engine once.
  engineOffer: false,

  setEngineOffer(on) {
    set({ engineOffer: on })
  },

  // Office files uploaded on a device with the engine but no engine window open, waiting for a
  // click to open one (lib/disk/engine/rendition.js): { id, orgId, file, name, versionId, Kv }.
  // In memory only: closing the tab leaves those files without a rendition, in quick view.
  renditions: [],
  renditionsRunning: false,
  addRendition(r) {
    set((s) => ({ renditions: [...s.renditions, r] }))
  },
  dropRendition(id) {
    set((s) => ({ renditions: s.renditions.filter((r) => r.id !== id) }))
  },
  setRenditionsRunning(on) {
    set({ renditionsRunning: on })
  },

  add(list) {
    set((s) => ({ items: [...s.items, ...list] }))
  },
  patch(id, changes) {
    set((s) => ({ items: s.items.map((it) => (it.id === id ? { ...it, ...changes } : it)) }))
  },
  remove(id) {
    set((s) => ({ items: s.items.filter((it) => it.id !== id) }))
  },
  clearFinished() {
    set((s) => ({ items: s.items.filter((it) => ![UPLOAD_STATE.DONE, UPLOAD_STATE.CANCELLED].includes(it.state)) }))
  },
  setConflictAll(choice) {
    set({ conflictAll: choice })
  },
}))

export default useUploadStore
