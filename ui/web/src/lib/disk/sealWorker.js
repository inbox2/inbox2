// Seals upload parts off the main thread (6.6). The page sends the File and the
// content key C once, then asks for parts by number; each part is sealed from
// only the chunks that overlap it, so the file is never held whole and a failed
// part can be sealed again. Chunk tags come back with each part for the manifest.
import { init, sealPart } from './crypto'

let job = null

self.onmessage = async ({ data }) => {
  try {
    if (data.start) {
      await init()
      job = data.start // { file, C, prefix, chunkBytes, partBytes }
      return self.postMessage({ id: data.id, ok: true })
    }
    if (data.part) {
      const tags = []
      const bytes = await sealPart(data.part, job.file, job.C, job.prefix, job.chunkBytes, job.partBytes, (i, tag) => tags.push([i, tag.slice()]))
      return self.postMessage({ id: data.id, bytes, tags }, [bytes.buffer])
    }
    if (data.stop) {
      job = null
      self.close()
    }
  } catch (e) {
    self.postMessage({ id: data.id, error: e.message })
  }
}
