// Reads a presigned download URL. Renderers that need the whole file use these;
// media and zip read ranges instead.
async function get(url, signal) {
  const res = await fetch(url, { signal })
  if (!res.ok) throw new Error(`The file did not load (${res.status})`)
  return res
}
export const fetchBuffer = async (url, signal) => (await get(url, signal)).arrayBuffer()
export const fetchText = async (url, signal) => (await get(url, signal)).text()
export const fetchBlob = async (url, signal) => (await get(url, signal)).blob()
