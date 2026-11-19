# Model Manager — three-lane on-device models for the Bridge

Status: **all iOS slices implemented.** Rust core (manifest + availability + selection +
download + `.tar.bz2` extraction) with tests, the FFI surface (incl. OpenAI STT), the
three-lane settings screen, and the three free-lane engines are wired:
- **TTS** — Kokoro via sherpa-onnx (`KokoroSpeaker.swift`), model through the manager.
- **STT** — no free lane on iOS anymore: Apple `SpeechAnalyzer` (iOS 26, OS-managed
  assets) covers it, so the WhisperKit lane was removed. OpenAI `gpt-4o-transcribe`
  lane in core; routing resolved Swift-side (`ListeningManager`).
- **NLU** — Gemma via LiteRT/MediaPipe, routed by `BridgeLLM.swift` (Apple FM ↔ LiteRT).

Each neural engine is gated (`#if canImport(WhisperKit)` / `canImport(MediaPipeTasksGenAI)`
/ the `BRIDGE_KOKORO` flag for the vendored sherpa-onnx) so the app builds without the SDKs
and the lane gracefully falls back; add the dependency (see `ui/ios/project.yml`) to
activate it. **Free-model download URLs/hashes are provisional — pin before shipping.**
Android (slice 5) remains greenfield (the shared core already supports it; see §8 + the
iOS-App.md Android-port notes).

Give each Bridge capability — **TTS**, **STT**, **NLU/routing** — exactly three selectable
**lanes**, and a manager in the Rust core that knows which lanes the current device supports,
downloads the one free best-in-class model on demand, and routes accordingly.

| Lane | What | Cost | Download |
|------|------|------|----------|
| `native` | the OS's built-in engine | free, private | none — **hidden if the device can't do it** |
| `free` | one downloadable open model, consistent quality on any modern device | free, private | on first use (never bundled) |
| `openai` | the user's own API key, cloud | paid | none |

No older-device floor, no degradation ladder, no min-RAM tiers. Target current-gen hardware.
If `native` is unavailable, `free` is the fallback. **No streaming** — utterances are fully
generated before TTS, so we synthesize whole strings.

Single source of truth (manifest + availability + selection + download) lives in **`core/src/bridge/models/`**.
iOS/Android call FFI and own only UI + audio I/O + the inference engines themselves.

---

## 1. The three lanes per capability

| Capability | `native` | `free` (downloadable) | `openai` |
|-----------|----------|------------------------|----------|
| **TTS** | Apple `AVSpeechSynthesizer` / Android `TextToSpeech` | **Kokoro-82M** (sherpa-onnx) — **the recommended default**, native voices are robotic | `tts-1` (existing path) |
| **STT** | Apple `SpeechAnalyzer` (iOS 26) / Android `SpeechRecognizer` | none on iOS (SpeechAnalyzer made Whisper redundant); sherpa-onnx whisper an option for Android/desktop | `gpt-4o-transcribe` |
| **NLU/routing** | Apple Foundation Models (iOS 26+, AI hardware) — existing `AppleLLM` | **gemma3-1b** via LiteRT/MediaPipe (default); evaluate `functiongemma-270m` | `gpt-4o-mini` |

NLU note: Android has **no** native LLM lane, so there `free` *is* the on-device path. On iOS,
`functiongemma-270m` is a routing-specialized alternative to gemma3-1b — smaller, tool-call-tuned;
decide during the NLU slice by measuring routing accuracy on our tool catalog (`bridge/tools.rs`).

### Free-model sources (canonical; **pin sha256 + bytes at implementation**)

The manifest ships **embedded** but is **remotely overridable**, so exact URLs/hashes are pinned
in `models.json` at build time and can be hot-swapped without an app update. Approximate sizes:

| Model | Engine | Source (canonical) | ~Size | License |
|-------|--------|--------------------|-------|---------|
| Kokoro-82M | sherpa-onnx | k2-fsa/sherpa-onnx releases, `tts-models/kokoro-multi-lang-v1_0.tar.bz2` (model.onnx + voices.bin + tokens) | ~300 MB fp32 (int8 ~80–150 MB — evaluate) | Apache-2.0 |
| whisper-large-v3-turbo (iOS) | WhisperKit/CoreML | HF `argmaxinc/whisperkit-coreml`, `openai_whisper-large-v3-v20240930_turbo` | ~1.5–1.6 GB | MIT |
| whisper-large-v3-turbo (Android/desktop) | sherpa-onnx | k2-fsa/sherpa-onnx whisper turbo int8 release asset | ~0.8–1.6 GB | MIT |
| gemma3-1b | LiteRT/MediaPipe | HF `litert-community/Gemma3-1B-IT`, `*_q8_ekv2048.litertlm` | ~0.5–1 GB | Gemma (permissive, redistributable) — **confirm before shipping** |
| functiongemma-270m | LiteRT | HF (function-calling Gemma 270M `.task`/`.litertlm`) | ~0.3 GB | Gemma — **confirm** |

Only ship permissive (MIT/Apache) free models; **Gemma terms must be confirmed acceptable** before
the NLU slice ships, else hold NLU `free` to Apple-native + OpenAI only on iOS.

---

## 2. Manifest schema (`core/src/bridge/models/models.json`)

Embedded via `include_str!` (like `SCHEMA_SQL`), with an optional remote override URL cached under
`<dataDir>/models/manifest.json`. One entry per (capability × lane). `native`/`openai` lanes carry
no `files`.

```jsonc
{
  "version": 3,
  "models": [
    {
      "id": "kokoro-82m-v1",
      "capability": "tts",                       // tts | stt | nlu
      "lane": "free",                            // native | free | openai
      "engine": "sherpa-onnx",                   // native | sherpa-onnx | whisperkit | coreml | litert | openai
      "files": [                                  // omitted for native/openai
        { "url": "https://…/kokoro-multi-lang-v1_0.tar.bz2", "sha256": "…", "bytes": 314572800 }
      ],
      "total_bytes": 314572800,
      "license": "Apache-2.0",
      "platforms": ["ios", "android", "macos", "windows", "linux"],
      "availability_reqs": {},                    // native lanes only (see below)
      "langs": ["en", "…"],
      "voices": ["af_heart", "am_adam", "…"]      // tts only
    },
    {
      "id": "apple-avspeech", "capability": "tts", "lane": "native", "engine": "native",
      "total_bytes": 0, "license": "system",
      "platforms": ["ios", "macos"], "availability_reqs": {}, "langs": ["*"], "voices": []
    },
    {
      "id": "apple-foundation-models", "capability": "nlu", "lane": "native", "engine": "native",
      "total_bytes": 0, "license": "system", "platforms": ["ios"],
      "availability_reqs": { "min_ios": 26, "requires_apple_intelligence": true }
    }
    // … one native + one free + one openai entry per capability
  ]
}
```

`availability_reqs` fields: `min_ios?`, `requires_apple_intelligence?`, `android_native?` (e.g. STT
native needs `android_native: true` on Android).

---

## 3. Availability resolver (pure, unit-tested)

Host passes a device profile once; the resolver is a pure function over (manifest, profile).

```
DeviceProfile { os: ios|android|macos|windows|linux, os_version: (maj,min),
                apple_intelligence: bool, android_native_speech: bool }

native_available(cap, device):
  entry = manifest.native(cap)
  if entry is None or device.os not in entry.platforms: false
  reqs = entry.availability_reqs
  if reqs.min_ios and device.os==ios and device.os_version.maj < reqs.min_ios: false
  if reqs.requires_apple_intelligence and not device.apple_intelligence: false
  if reqs.android_native and device.os==android and not device.android_native_speech: false
  else true

lanes(cap, device, has_valid_key, downloaded_ids):
  native: available = native_available(cap, device)
  free:   available = device.os in manifest.free(cap).platforms     // always downloadable on supported os
          state     = installed if id in downloaded_ids else absent
  openai: available = has_valid_key
  // unavailable lanes carry a human reason ("Needs iOS 26 + Apple Intelligence", "Add an OpenAI key", …)
```

Examples: iOS-26 Apple-Intelligence phone → NLU shows all three; older iPhone → NLU native hidden,
free+openai only. Android → STT native only if `android_native_speech`, NLU native always hidden.

---

## 4. Selection (pure, unit-tested)

```
effective_lane(cap, user_pref, device, has_valid_key, free_downloaded):
  if user_pref == openai and has_valid_key:                 return openai
  if user_pref == native and native_available(cap,device):  return native
  if free_downloaded(cap):                                  return free
  if native_available(cap, device):                         return native
  return NeedsDownload(free)        // offline + no native: UI must prompt the download

Default user_pref:  STT, NLU → native (if available)
                    TTS      → free (Kokoro)
```

TTS default is `free`, but until Kokoro is downloaded the chain falls back to native Apple, so the
Bridge always speaks offline; the panel separately **nudges** the Kokoro download on first use. With
no key and no download, native lanes always work; if native is unavailable the UI routes the user to
the free download. OpenAI key handling is unchanged (Keychain, client-side, straight to api.openai.com).

---

## 5. Download manager (Rust core)

On-demand only, never bundled. Lives in `core/src/bridge/models/download.rs`.

- **Resumable**: HTTP `Range` from the existing `.partial` size; `reqwest` async byte stream (add the
  `stream` feature) into `<dataDir>/models/<id>/.partial/<file>`.
- **Verify**: sha256 each file against the manifest (**add `sha2` dep**); mismatch → discard + fail.
- **Atomic install**: verify all files, then `rename()` `.partial/` → `<dataDir>/models/<id>/`. Reads
  only ever see a complete, verified dir.
- **Delete / reclaim**: remove the dir; `lanes()` reports `absent` again.
- **Wi-Fi-only**: a stored pref; **the host enforces it** (iOS `NWPathMonitor`, Android
  `ConnectivityManager`) by choosing when to start/pause — keeps core network-portable. Core exposes
  `pause`/`resume` and emits a `waiting-for-wifi` state.
- **Untar**: Kokoro/whisper assets are `.tar.bz2`; unpack after verify (add a small `tar` + `bzip2`
  decode, or pin already-unpacked per-file URLs in the manifest to avoid the dep — prefer per-file URLs).

**Progress/state over FFI = the existing event bus**, not a new streaming primitive (UniFFI async is
deferred per `ffi.rs`). Emit through `EngineEventListener.on_event`:

```
event: "model-download"
payload: { id, capability, lane:"free", state, received_bytes, total_bytes, error? }
state ∈ absent | downloading | waiting-for-wifi | verifying | installing | installed | failed | paused
```

iOS already consumes this bus in `EngineModel`; the panel subscribes and renders the progress row.

---

## 6. Inference wiring — sherpa-rs vs native (recommendation: **hybrid**)

Orchestration (manifest / availability / selection / download) stays in Rust **for every platform**.
The inference engines differ because audio I/O already lives in Swift (`Speaker`/`ListeningManager`)
and the best mobile runtimes ship as native packages:

| Capability | iOS | Android | Desktop |
|-----------|-----|---------|---------|
| TTS free | **sherpa-onnx Swift** xcframework (k2-fsa) → PCM → `AVAudioEngine` player node | sherpa-onnx (JNI) | **sherpa-rs** in core |
| STT free | **WhisperKit** (Swift/CoreML), owns its audio | sherpa-onnx whisper (JNI) | **sherpa-rs** in core |
| NLU free | **MediaPipe/LiteRT** LLM Inference (Swift) | **LiteRT** (the on-device path) | sherpa-rs / llama sidecar (reuse existing `NativeLLM`) |

Rationale: on mobile, keep model **bytes** out of the FFI hot path — Swift/Kotlin run the engine on
the buffers they already hold (mic frames, PCM out). On desktop there's no native audio layer, so
**sherpa-rs** unifies TTS+STT inside the core. The manager doesn't care which engine runs; it only
resolves the lane and guarantees a verified model dir on disk at `<dataDir>/models/<id>/`.

---

## 7. FFI surface (UniFFI additions to `core/src/ffi.rs`)

```rust
#[derive(uniffi::Record)] FfiDeviceProfile { os, os_major, os_minor,
                                             apple_intelligence: bool, android_native_speech: bool }
#[derive(uniffi::Record)] FfiLaneInfo { lane, id, available: bool, reason: Option<String>,
                                        state, total_bytes: u64, license }

impl InboxEngine {
  fn set_device_profile(&self, p: FfiDeviceProfile);                 // once at launch
  fn model_lanes(&self, capability: String) -> Vec<FfiLaneInfo>;     // for the panel
  fn effective_lane(&self, capability: String, user_pref: String,
                    has_valid_key: bool) -> String;                  // routing decision
  fn model_download(&self, id: String) -> Result<(), FfiError>;      // background; progress via events
  fn model_delete(&self, id: String) -> Result<(), FfiError>;
  fn model_path(&self, id: String) -> Option<String>;               // verified dir for the native engine
}
```

Prefs (`native`/`free`/`openai` per capability) stay **host-side**, persisted in `VoiceEngineManager`
alongside today's `sttSource/ttsSource/genSource`, and passed into `effective_lane`. `setPreference`
is therefore host persistence (no core call); `effective_lane`/`model_lanes` are pure core queries.
The Wi-Fi-only pref is also host-side.

iOS `VoiceSource{apple,openai}` → new `BridgeLane{native,free,openai}`. Migrate old UserDefaults
values: `apple→native`, `openai→openai` (`free` is new). NLU's `FfiBridgeConfig.generation` (today
`"apple"|"openai"`) gains `"free"` when the NLU slice lands.

---

## 8. UI

**iOS `BridgeVoicePanel.swift`** — per capability, replace the two-option Menu with a three-option
segmented control (Native / Best free / OpenAI):
- unavailable lanes **disabled with the resolver's reason** ("Needs iOS 26 + Apple Intelligence");
- the `free` lane shows a **download/delete row** — size, license, progress bar fed by the
  `model-download` events;
- `openai` stays gated behind the validated key (unchanged).

Route `Speaker`/`ListeningManager` through `effective_lane(capability, …)` instead of the hard-coded
Apple/OpenAI branch.

**Android** — the repo has no Android voice client yet. v1: **scaffold the manager UI + audio glue
as a thin stub** (lanes list, download row, native TTS/STT wired; free engines stubbed) and call it
out as a stub; full LiteRT/sherpa-onnx Android inference is a follow-up. The Rust manager is already
shared, so Android only adds the UI + JNI engine glue later.

---

## 9. Phasing (reviewable slices)

1. **Rust core + tests** — manifest, availability resolver, selection, download manager, FFI
   (`set_device_profile`, `model_lanes`, `effective_lane`, `model_download/delete/path`, events).
   `sha2` + reqwest `stream`. No behavior change: lanes still resolve to native/openai as today.
2. **iOS TTS Kokoro** — sherpa-onnx Swift package, `KokoroSpeaker`, route `Speaker` via
   `effective_lane`, three-lane Voice-output UI with the download/delete row. **Biggest visible win.**
3. **iOS STT** — WhisperKit free lane; route `ListeningManager`.
4. **iOS NLU** — MediaPipe/LiteRT free lane (or stub), native via existing `AppleLLM`; extend
   `FfiBridgeConfig.generation`. Confirm Gemma license first.
5. **Android** — scaffold the three-lane surface + native audio; free engines follow.

Out of scope for v1: the web/desktop classifier pipeline (`ui/web/src/lib/ai/`) is untouched.
</content>
