# Streaming the free Kokoro TTS lane

Status: **plan — awaiting review.** Scope: the **free / Kokoro TTS lane only**. The
OpenAI `tts-1` (MP3 → `AVAudioPlayer`) path and the Apple `AVSpeechSynthesizer` native
lane are untouched. No text-generation change — briefs arrive fully written; this is
purely synthesis → playback.

Goal: cut time-to-first-audio on multi-sentence briefs by **playing segment N while N+1
synthesizes**, instead of synthesizing the whole utterance and then playing it.

See `docs/model-manager.md` §6 for the three-lane inference-location table (this plan
realizes the "TTS free → sherpa-onnx Swift → PCM → `AVAudioEngine` player node" row).

---

## 1. What's already true (so we don't fight Kokoro)

- Kokoro is **non-autoregressive** — no sub-utterance sample streaming inside one forward
  pass. "Streaming" = segment the text, one synth pass per segment, overlap synth(N+1)
  with playback(N). sherpa-onnx already chunks by sentence and fires a per-chunk callback.
- **Inference already runs in-process in Swift.** `KokoroEngine` (`KokoroSpeaker.swift`,
  `#if BRIDGE_KOKORO`) wraps `SherpaOnnxOfflineTtsWrapper` directly. Kokoro does **not**
  cross the Rust FFI — only manifest / selection / download / `model_path` do, and those
  stay unchanged. So the callback stays in the same process as the audio engine with **no
  per-chunk FFI marshalling**. This satisfies the model-manager §6 "native sherpa-onnx
  Swift on iOS" recommendation with zero new FFI.
- The vendored wrapper **already exposes the callback API** we need:
  - `generateWithCallbackWithArg(text:callback:arg:sid:speed:)`
  - callback type `TtsCallbackWithArg = (UnsafePointer<Float>?, Int32 n, arg) -> Int32`
  - **return `1` to continue, `0` to stop** — already plumbed through to the C API.
  - `sherpaOnnxOfflineTtsConfig(model:maxNumSentences:silenceScale:)` — `maxNumSentences`
    is currently defaulted to `1` (one synth/callback per sentence).
- Kokoro output is **24 kHz mono float32**; `SherpaOnnxGeneratedAudioWrapper.sampleRate`
  reports it per call. We feed those floats straight to the player node — no resample.

## 2. Inference-location decision

**Keep Kokoro inference native in Swift (`KokoroEngine`), switch from `generate(...)` to
the callback API.** No FFI callback/channel is introduced.

Justification:
- The callback fires in whatever process runs Kokoro. Kokoro already runs in-process in
  Swift, so the callback lands next to `AVAudioEngine` — we schedule each chunk's PCM
  directly onto the player node from the synth thread, no marshalling, no copy across the
  UniFFI boundary.
- A Rust-side sherpa-rs callback would have to ferry every 24 kHz float buffer back over
  FFI per chunk — the exact hot-path cost model-manager §6 says to avoid on mobile.
- The Rust core's role (manifest, availability, selection, download, `model_path`) is
  unchanged. We only swap the Swift synth call and the playback engine.

(Desktop keeps sherpa-rs in core per §6 — out of scope here.)

## 3. Segmentation (minimize first-audio latency)

Two layers, both Swift-side, before synthesis:

1. **Pre-split** the brief into segments so the *first* segment is short:
   - Split on sentence-final `.` `?` `!` first.
   - If a resulting sentence exceeds `KOKORO_SEGMENT_MAX_CHARS` (a constant, start at
     **120**), further split it on clause delimiters `; : ,` — but only at a delimiter that
     leaves both sides non-trivial (≥ a small min run), so we don't chop "3,000".
   - Trim empties; collapse a too-short trailing fragment into the previous segment.
2. **`maxNumSentences = 1`** on the sherpa config, so within a segment sherpa still emits
   one chunk per internal sentence (defense-in-depth for any sentence our splitter missed).

Then synthesize **segment by segment** via `generateWithCallbackWithArg`. The loop is what
overlaps work: while `generateWithCallbackWithArg(segment N+1)` blocks on synthesis, the
engine is already playing segment N's scheduled buffers. First-audio latency collapses to
"synthesize segment 0" instead of "synthesize the whole brief."

`KOKORO_SEGMENT_MAX_CHARS` and the clause-split min-run live as named constants next to the
Kokoro lane (not magic numbers).

> Note: keep the existing NaturalLanguage *language*-segmentation as-is for the **Apple**
> lane (`Speaker.languageSegments`). Kokoro's English-only voice catalog doesn't need it;
> the clause splitter above is independent and Kokoro-lane-only.

## 4. Playback rewrite (Kokoro lane only)

Replace `WAVWriter` → `playOpenAI` (`AVAudioPlayer`) **for the Kokoro lane** with a
persistent `AVAudioEngine` + `AVAudioPlayerNode`:

- One `AVAudioEngine`, one `AVAudioPlayerNode`, created lazily and reused. Player-node /
  mixer format = **24 kHz, 1 channel, float32, non-interleaved** to match Kokoro exactly.
- Per callback chunk: copy `samples` (valid only during the callback) into an
  `AVAudioPCMBuffer` of that format, then `playerNode.scheduleBuffer(buf)` — gapless,
  FIFO. Start the engine + `playerNode.play()` lazily on the **first** chunk.
- `isSpeaking` → `true` on the first scheduled buffer. → `false` when **synthesis is done
  AND every scheduled buffer has drained** (track outstanding buffers via
  `scheduleBuffer`'s completion handler; when count hits 0 and the synth loop has
  returned, stop the engine and clear state).
- This is a new private path (`playKokoroStreaming` / a small `KokoroStreamPlayer` helper);
  `playOpenAI` and the Apple path are left exactly as they are.

### Orb metering (preserve `isSpeaking` + `level`)

- Compute amplitude **per incoming buffer** as RMS over the chunk's float samples, mapped
  to 0…1, then push to `level` on the `MainActor`.
- Reuse today's smoothing feel: keep the `*= 0.82` decay timer (as in `startAppleDecay`)
  running during Kokoro playback so `level` falls between chunks; each chunk's RMS bumps it
  up. No `AVAudioPlayer.averagePower` (that player isn't in this path anymore).

## 5. Barge-in / cancel

`speaker.stop()` stays the single barge-in entry point (orb tap, new command via `run`,
press-start — all already call it). New wiring:

- A small thread-safe **cancel token** (`final class`, lock-guarded `Bool`, or
  `OSAllocatedUnfairLock`) shared with the running synth. The C callback reads it and
  **returns `0`** to abort sherpa mid-utterance; the segment loop checks it between
  segments and breaks.
- `stop()` additionally: `playerNode.stop()`, flush scheduled buffers (`playerNode.stop()`
  discards them), `engine.pause()` (keep the engine allocated for reuse), reset
  `isSpeaking = false`, `level = 0`, cancel the decay timer — same teardown contract as
  today.
- Each new utterance gets a fresh cancel token so a late callback from a cancelled run
  can't touch the new one.

## 6. Edge cases

- **First-chunk failure / empty audio:** if the streaming run produces **zero** scheduled
  buffers (no chunk ever fired, or all empty), fall back to the existing **non-streaming
  `generate`** for that same utterance (→ `WAVWriter` → existing WAV playback). If *that*
  is also empty, fall back to the Apple voice — i.e. the current `speakApple` fallback is
  preserved as the final tier. Never fail silently.
- **Very short brief (one segment):** the streaming path still runs — one segment, one (or
  few) chunks. No regression vs the old path; it's strictly the old path minus the
  "buffer the whole thing first" wait.
- **AVAudioSession interruptions & route changes:** the old `AVAudioPlayer` handling
  doesn't carry over, so the engine handles them explicitly:
  - keep `activatePlaybackSession()` (`.playback` / `.spokenAudio`) before starting.
  - observe `AVAudioSession.interruptionNotification` → on `.began`, `stop()`.
  - observe `routeChangeNotification` → on `.oldDeviceUnavailable` (e.g. headphones
    unplugged), `stop()`.
  - observe `AVAudioEngineConfigurationChange` → rebuild/restart the engine graph before
    the next utterance (format/route changed under us).

## 7. Android (note only — not in this slice)

Mirror later: feed the same clause-segmented text to sherpa-onnx (JNI) with a per-chunk
callback, and schedule each chunk into an `AudioTrack` in `MODE_STREAM` at 24 kHz mono
float (`ENCODING_PCM_FLOAT`). Same cancel-via-return-0 and RMS metering. Not implemented
here.

## 8. Implementation slices (each independently reviewable)

a. **Segmentation + callback wiring.** Add the clause splitter + constants; add
   `KokoroCache.synthesizeStreaming(text:modelDir:speakerId:onChunk:)` (actor method) that
   loops segments calling `generateWithCallbackWithArg`, invoking a `@Sendable` `onChunk`
   that returns continue/stop. **Test:** assert the first chunk is delivered *before* full
   synthesis completes (e.g. timestamp first `onChunk` vs. the call's return) on a
   multi-sentence input — guards the core latency win. (Runs only with `BRIDGE_KOKORO`; a
   fake engine drives the test where the SDK isn't linked.)

b. **`AVAudioEngine` streaming playback + orb metering.** `KokoroStreamPlayer`
   (engine + player node, schedule-per-chunk, outstanding-buffer drain detection),
   per-buffer RMS → `level`, `isSpeaking` lifecycle. Route `Speaker.speak` free lane to it.

c. **Barge-in + interruption/route handling.** Cancel token wired to `stop()`; session
   interruption / route-change / engine-config observers; fallback tiers (streaming →
   non-streaming `generate` → Apple).

Diff stays confined to: `Speaker.swift` (free-lane branch + new player), `KokoroSpeaker.swift`
(streaming synth method + constants), and a test. Flagged risk surface: none of the OpenAI
or Apple branches in `Speaker.swift` are modified — `playOpenAI`, `speakApple`, and the
`AVSpeechSynthesizerDelegate`/`AVAudioPlayerDelegate` callbacks stay byte-for-byte.
