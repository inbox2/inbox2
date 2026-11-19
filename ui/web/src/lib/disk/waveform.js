// The audio preview's waveform (spec F5): peaks downsampled from the decoded
// audio. No dependency; Web Audio decodes, a canvas draws.

/** Above this the file is not fetched whole for a waveform: decoding holds the PCM in memory. */
export const WAVEFORM_MAX_BYTES = 15 * 1024 * 1024
export const WAVEFORM_BARS = 160

/** The loudest absolute sample in each of `bars` equal slices, 0..1. */
export function peaks(samples, bars = WAVEFORM_BARS) {
  const out = new Float32Array(bars)
  const per = samples.length / bars
  // ponytail: reads about 256 samples per bar, not all of them; exact peaks would scan every sample.
  const step = Math.max(1, Math.floor(per / 256))
  for (let b = 0; b < bars; b++) {
    let max = 0
    for (let i = Math.floor(b * per), end = Math.floor((b + 1) * per); i < end; i += step) {
      const v = Math.abs(samples[i])
      if (v > max) max = v
    }
    out[b] = Math.min(1, max)
  }
  return out
}

export const waveformSupported = () => !!(globalThis.OfflineAudioContext || globalThis.webkitOfflineAudioContext)

/** Decodes a whole audio file and returns its peaks; throws when the browser cannot decode it. */
export async function decodePeaks(buffer, bars = WAVEFORM_BARS) {
  const Ctx = globalThis.OfflineAudioContext || globalThis.webkitOfflineAudioContext
  const audio = await new Ctx(1, 1, 44100).decodeAudioData(buffer)
  return peaks(audio.getChannelData(0), bars)
}
