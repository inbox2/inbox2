// Dropped or picked files as a flat list of { file, relativePath }, where
// relativePath keeps the folder structure ("Q4/Budget/plan.xlsx") so the
// uploader can recreate the tree (spec F2: dropping a folder).
// ponytail: empty folders carry no file and are not reported; add directory entries if the uploader needs them.

/** From a drop event's DataTransfer. Must be called inside the drop handler: entries expire after it. */
export async function filesFromDataTransfer(dt) {
  const entries = [...(dt.items || [])].filter((i) => i.kind === 'file').map((i) => i.webkitGetAsEntry?.())
  if (!entries.length || entries.some((e) => !e)) return filesFromInput(dt.files)
  const out = []
  for (const entry of entries) await walk(entry, '', out)
  return out
}

/** From an <input type="file">'s FileList (with or without webkitdirectory). */
export function filesFromInput(fileList) {
  return [...(fileList || [])].map((file) => ({ file, relativePath: file.webkitRelativePath || file.name }))
}

async function walk(entry, prefix, out) {
  const path = prefix + entry.name
  if (entry.isFile) {
    out.push({ file: await new Promise((res, rej) => entry.file(res, rej)), relativePath: path })
    return
  }
  const reader = entry.createReader()
  // readEntries returns at most ~100 entries per call; keep reading until empty.
  for (;;) {
    const batch = await new Promise((res, rej) => reader.readEntries(res, rej))
    if (!batch.length) return
    for (const child of batch) await walk(child, `${path}/`, out)
  }
}
