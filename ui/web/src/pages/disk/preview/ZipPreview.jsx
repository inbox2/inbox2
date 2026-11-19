import { useEffect, useState } from 'react'
import formatBytes from '../../../lib/formatBytes'
import { saveUrl } from '../../../lib/disk/download'
import { fileType } from '../../../lib/disk/fileTypes'
import styles from './Preview.module.css'

const ENTRY_PREVIEW_MAX = 5 * 1024 ** 2

/* A zip's contents, read with range requests (zip.js), so a 1 GB archive lists
   after fetching only its tail. One entry can be opened without the rest. */
export default function ZipPreview({ url, onReady, onError }) {
  const [entries, setEntries] = useState(null)
  const [open, setOpen] = useState(null) // { name, kind: 'image' | 'text', value }
  useEffect(() => {
    let reader
    ;(async () => {
      const { ZipReader, HttpRangeReader, BlobReader, configure } = await import('@zip.js/zip.js')
      configure({ useWebWorkers: false })
      // A sealed zip arrives decrypted as a blob: URL, which takes no HEAD or Range: read it whole.
      reader = new ZipReader(url.startsWith('blob:')
        ? new BlobReader(await (await fetch(url)).blob())
        : new HttpRangeReader(url, { useRangeHeader: true, forceRangeRequests: true }))
      setEntries(await reader.getEntries())
      onReady()
    })().catch(onError)
    return () => { reader?.close().catch(() => {}) }
  }, [url, onReady, onError])

  const show = async (entry) => {
    const { BlobWriter, TextWriter } = await import('@zip.js/zip.js')
    const kind = fileType({ name: entry.filename }).preview
    if (kind === 'image' && entry.uncompressedSize <= ENTRY_PREVIEW_MAX) {
      setOpen({ name: entry.filename, kind: 'image', value: URL.createObjectURL(await entry.getData(new BlobWriter())) })
    } else if (['text', 'markdown'].includes(kind) && entry.uncompressedSize <= ENTRY_PREVIEW_MAX) {
      setOpen({ name: entry.filename, kind: 'text', value: await entry.getData(new TextWriter()) })
    } else {
      saveUrl(URL.createObjectURL(await entry.getData(new BlobWriter())), entry.filename.split('/').pop())
    }
  }

  if (!entries) return null
  return (
    <div className={styles.doc}>
      <ul className={styles.zip}>
        {entries.map((e) => (
          <li key={e.filename}>
            {e.directory
              ? <span className={styles.zipDir}>{e.filename}</span>
              : <button type="button" className={styles.zipEntry} onClick={() => show(e).catch(onError)}>{e.filename}</button>}
            <span className={styles.zipSize}>{e.directory ? '' : formatBytes(e.uncompressedSize)}</span>
          </li>
        ))}
      </ul>
      <p className={styles.note}>{entries.filter((e) => !e.directory).length} files. Choose one to open it. Other types download.</p>
      {open && (
        <div className={styles.zipOpen}>
          <b>{open.name}</b>
          {open.kind === 'image' ? <img className={styles.image} src={open.value} alt={open.name} /> : <pre className={styles.raw}>{open.value}</pre>}
        </div>
      )}
    </div>
  )
}
