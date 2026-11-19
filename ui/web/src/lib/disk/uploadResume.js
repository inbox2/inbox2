// Unfinished uploads, kept in IndexedDB so a reload can resume them
// (GET /uploads/:id says which parts storage already has). Records hold ids and
// file facts only, never the bytes: the person picks the file again to resume.
// Every call fails soft: private windows and blocked storage just lose resume.
const DB = 'inbox2-disk'
const STORE = 'uploads'

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'id' })
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

async function tx(mode, fn) {
  try {
    const db = await open()
    return await new Promise((resolve, reject) => {
      const t = db.transaction(STORE, mode)
      const req = fn(t.objectStore(STORE))
      t.oncomplete = () => resolve(req?.result)
      t.onerror = () => reject(t.error)
    })
  } catch {
    return undefined
  }
}

export const resumeStore = {
  put: (record) => tx('readwrite', (s) => s.put(record)),
  del: (id) => tx('readwrite', (s) => s.delete(id)),
  all: async () => (await tx('readonly', (s) => s.getAll())) || [],
}
