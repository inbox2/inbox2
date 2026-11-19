// Streaming sha256 (libsodium), so a large file or engine part is never held whole.
export async function sha256Stream(stream, signal) {
  const { default: sodium } = await import('libsodium-wrappers-sumo')
  await sodium.ready
  const state = sodium.crypto_hash_sha256_init()
  const reader = stream.getReader()
  for (;;) {
    if (signal?.aborted) { reader.cancel(); throw Object.assign(new Error('Stopped'), { aborted: true }) }
    const { done, value } = await reader.read()
    if (done) break
    sodium.crypto_hash_sha256_update(state, value)
  }
  return sodium.to_hex(sodium.crypto_hash_sha256_final(state))
}
