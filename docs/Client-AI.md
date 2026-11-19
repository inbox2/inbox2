# Client-Side AI

> The model **lanes** (native/free/openai per capability), the prompt template
> file, and the triage eval harness are documented in
> [AI-Lanes-and-Eval.md](AI-Lanes-and-Eval.md). This document covers the desktop
> Tier A/B inference stack (ONNX classification, Apple FM bridge, llama-server
> sidecar, WebLLM) those lanes run on.

On-device AI for email classification, summarization, and smart replies. All inference here runs locally — no email content leaves the user's machine.

> Thread **triage** (label, priority, Space) is not part of this stack: since
> 2026-09-19 it is Jev (TypeSafe's hosted model), called with the user's own key,
> so a triaged thread's text does go to TypeSafe. See [Triage.md](Triage.md).

## Architecture overview

```
┌─────────────────────────────────────────────────────────┐
│  UI Components                                          │
│  AISummaryPanel · AIInsightsPanel · SmartReplyBar        │
│  AIBadge · SummarizeButton · AIOnboardingModal           │
└──────────┬──────────────────────────────┬────────────────┘
           │                              │
    ┌──────▼──────┐              ┌────────▼────────┐
    │  Tier A     │              │  Tier B          │
    │  inference  │              │  generative      │
    │  .js        │              │  /index.js       │
    └──────┬──────┘              └────────┬─────────┘
           │                              │
     ┌─────┴──────────┐          ┌────────┴──────────────┐
     │ Browser        │          │ Tauri (macOS)         │
     │ Web Worker     │          │ tauriProvider.js      │
     │ Transformers.js│          │   ↓ invoke()          │
     └────────────────┘          │ generative_commands.rs│
                                 │   ↓                   │
     ┌────────────────┐          │ apple_bridge.rs       │
     │ Browser        │          │   ↓ stdin/stdout      │
     │ webllmProvider │          │ FoundationModelsBridge│
     │ @mlc-ai/web-llm│          │   (Swift CLI)         │
     └────────────────┘          └───────────────────────┘
```

> The diagram shows the browser worker (Tier A) and the Tauri generative path (Tier B). On desktop, **Tier A also has a native path**: `inference.js → invoke('ai_sentiment'|'ai_intent'|'ai_embedding') → ai/inference.rs` (ONNX Runtime), used when Apple Intelligence isn't available and always for embeddings — see below.

## Tier A — Classification & Insights

Small encoder models for sentiment, intent, and embeddings. Runs on all devices.

### Backend selection (progressive matching)

| Environment | Backend | Runtime |
|---|---|---|
| Tauri (Apple Intelligence available) | Apple Intelligence | sentiment/intent via Swift bridge (structured prompts) |
| Tauri (no Apple Intelligence) | `tauri-ort` | native ONNX Runtime in Rust (`ai/inference.rs`) |
| Tauri — embeddings (any device) | `tauri-ort` | native ONNX Runtime (Apple FM can't embed) |
| Browser + WebGPU | `webgpu` | Transformers.js Web Worker |
| Browser (no WebGPU) | `wasm` | Transformers.js Web Worker (CPU) |

On desktop, sentiment/intent **prefer Apple Intelligence** when it's available (deterministic structured prompts), and fall back to a **native ONNX Runtime engine in Rust** when it isn't. Embeddings always use the native engine (Apple Foundation Models can't produce embeddings). The native engine loads the *same* INT8-quantized ONNX models the browser uses — via the [`ort`](https://crates.io/crates/ort) crate (ONNX Runtime 1.24, `download-binaries`) and the [`tokenizers`](https://crates.io/crates/tokenizers) crate.

`initializeInference()` waits briefly for the generative engine; if Apple Intelligence doesn't come up it warms the native engine (`warmup_ai_models`). On a no-Apple-Intelligence desktop this is what makes classification work at all — without it, `tauri-ort` would be a selected-but-undispatched backend.

In the browser, Transformers.js loads quantized ONNX models into a Web Worker:

| Model | Task | Repo | Size |
|---|---|---|---|
| DistilBERT SST-2 | Sentiment | `Xenova/distilbert-base-uncased-finetuned-sst-2-english` | ~67 MB |
| DeBERTa v3 xsmall NLI | Intent (zero-shot) | `Xenova/nli-deberta-v3-xsmall` | ~90 MB |
| all-MiniLM-L6-v2 | Embeddings | `Xenova/all-MiniLM-L6-v2` | ~23 MB |

Models are INT8 quantized ONNX. Configuration lives in `ui/web/src/lib/ai/models.js` — model identity is configuration, not hardcoded.

### Inference flow (browser)

1. `initializeInference()` spawns `inference.worker.js` (ES module Web Worker)
2. Worker loads pipelines via `@huggingface/transformers` (cached in IndexedDB)
3. Warmup inference runs on load so the first real call isn't slow
4. `analyzeSentiment(text)` / `classifyIntent(text)` post messages to the worker
5. Results cached in-memory by message ID via `useAIClassification` hook

### Inference flow (Tauri — Apple Intelligence)

1. `initializeInference()` waits for `isGenerativeReady()` (Apple Intelligence)
2. `analyzeSentiment(text)` sends a structured prompt: "Classify sentiment as POSITIVE or NEGATIVE. Return JSON."
3. Apple Intelligence responds with `{"label":"POSITIVE","score":0.95}`
4. Result parsed and returned to the UI

### Inference flow (Tauri — native ONNX)

Used when Apple Intelligence isn't available, and always for embeddings. `infer()` calls `ensureOrtWarm()` (idempotent `warmup_ai_models`), then invokes `ai_sentiment` / `ai_intent` / `ai_embedding`. Inside `ai/inference.rs`:

1. **warmup** loads the 3 ONNX sessions + HF tokenizers from `app_data_dir/models/{key}/`, introspecting each model's declared inputs so `token_type_ids` is supplied only when the graph expects it, and reads `config.json` `id2label` for label ordering.
2. **sentiment** — tokenize → run → softmax → argmax over the `id2label` labels → `{label, score}`.
3. **intent (zero-shot NLI)** — for each of the 6 candidate labels, encode the pair `(text, "This example is {label}.")`, run the NLI model, take the **entailment** logit, then softmax those logits across all labels. This mirrors the Transformers.js zero-shot pipeline (`multi_label: false`) → `{label, score, scores}`.
4. **embeddings** — tokenize → encoder → mean-pool token states with the attention mask → L2-normalize → 384-dim `{embedding, dimensions}`.

Result shapes are identical to the worker / Apple paths, so the UI is agnostic to which backend ran. If the models aren't downloaded, warmup fails gracefully and inference returns `null` (the app stays fully functional).

### UI integration

- **AI Insights panel** (`AIInsightsPanel`) — context sidebar, shows sentiment + intent with confidence percentages
- **AI Badges** (`AIBadge`) — inline on `MessageCard`, color-coded by type (green/red for sentiment, gold/purple/teal for intent)
- `useAIClassification(messageId, text)` hook manages async inference + caching per message

## Tier B — Generative (Summarization & Smart Replies)

Uses the device's most capable generative model. No additional download on macOS with Apple Intelligence.

### Backend selection

| Environment | Backend | Model source |
|---|---|---|
| Tauri + macOS + Apple Intelligence | `apple-foundation-models` | System on-device model (no download) |
| Tauri + macOS (no Apple Intelligence) | `tauri-native` | llama.cpp sidecar + GGUF download (~1.1 GB) |
| Tauri + Windows/Linux | `tauri-native` | llama.cpp sidecar + GGUF download (~1.1 GB) |
| Browser + WebGPU + 4GB+ RAM | `webgpu-webllm` | @mlc-ai/web-llm + model download |
| Browser (no WebGPU / low RAM) | `none` | Generative features hidden |

### Apple Foundation Models bridge

A Swift CLI binary at `ui/desktop/src-tauri/swift-bridge/` communicates with the Tauri Rust backend via JSON over stdin/stdout.

**Protocol** (one JSON object per line):

```
→  {"cmd":"check"}
←  {"available":true,"reason":null}

→  {"cmd":"summarize","text":"From: Alice..."}
←  {"summary":"• Alice requested the report\n• Bob confirmed Friday deadline"}

→  {"cmd":"smart_replies","email":"Can you review?","sender":"Alice"}
←  {"replies":["Sure, I'll review it today.","...","..."]}

→  {"cmd":"generate","system":"You are helpful.","prompt":"..."}
←  {"text":"...","error":null}
```

**Requirements:**
- macOS 26+ (Tahoe) with Apple Silicon
- Apple Intelligence enabled in System Settings (Mac and Siri language must match)
- No entitlements or provisioning profile needed for basic use
- Build: `cd ui/desktop/src-tauri/swift-bridge && swift build -c release`

**Rust side** (`ai/apple_bridge.rs`): spawns the Swift binary as a child process, sends JSON via stdin, reads responses from stdout. Shuts down on drop.

**Rust commands** (`ai/generative_commands.rs`): `initialize_generative` tries Apple FM first, falls back to native LLM. `generative_summarize`, `generative_smart_replies`, `generative_generate` route to whichever backend initialized.

### Native LLM sidecar (non-Apple path)

`ai/native_llm.rs` manages a llama.cpp-compatible server:
- Downloads a GGUF model (default: `Qwen2.5-1.5B-Instruct-q4_k_m`, ~1.1 GB)
- Starts `llama-server` on a free localhost port
- Communicates via OpenAI-compatible `/v1/chat/completions` HTTP API
- The server binary must be provided at `app_data_dir/bin/llama-server`

### WebLLM (browser path)

`generative/webllm.worker.js` runs `@mlc-ai/web-llm` in a Web Worker:
- Downloads and caches a quantized LLM in IndexedDB
- Default model: `Qwen2.5-1.5B-Instruct-q4f16_1-MLC`
- Requires WebGPU + sufficient device memory (4GB+)

### UI integration

- **AI Summary panel** (`AISummaryPanel`) — context sidebar, auto-triggers `summarizeThread()` on conversation open
  - Cached per conversation ID; cancelled on navigate-away
  - Renders markdown (bold, bullets) from Apple Intelligence via DOMPurify
  - Falls back to clean text preview when generative isn't available
  - Title dynamically switches between "AI Summary" and "Preview"
- **Smart Reply Bar** (`SmartReplyBar`) — 3 chip-style suggestions below the last message
- **Summarize Button** (`SummarizeButton`) — for threads with 3+ messages, inline above the message list

## Setup & consent flow

### Onboarding modal

`AIOnboardingModal` — shown once on first Tauri inbox load (1.5s delay). Presents the `AISetup` component in a modal overlay. Dismissed state stored in `localStorage` (`inbox2_ai_onboarding_dismissed`). Skipping is a first-class choice.

### AISetup component

Multi-phase flow: detecting → consent → downloading → done.

1. **Detecting** — runs `detectCapabilities()`, shows spinner
2. **Consent** — shows feature list, download size, runtime info, opt-in/skip buttons
3. **Downloading** — progress bar for Tier A models, then Tier B initialization
4. **Done** — checkmark status for both tiers, with reason if Tier B unavailable

In Tauri with Apple Intelligence: Tier A downloads are skipped (classification uses Apple Intelligence), Tier B says "no additional download needed."

### Settings

`AIFeaturesSettings` in both user settings (`/settings`) and org settings (`/:orgSlug/settings`) under the "AI" group:

- Toggle on/off with switch component
- Model status list with sizes
- Disk usage display
- Generative section (auto-initializes for Apple FM, shows download button for other backends)
- "Remove all AI models" button (clears consent, cache, and triggers re-setup on next enable)

## Model management

`modelManager.js` handles consent, download, caching, and removal:

- **Consent**: `localStorage` key `inbox2_ai_consent` — `'granted'` or absent
- **Model metadata**: `localStorage` key `inbox2_ai_models` — JSON with version + downloadedAt per model
- **Browser cache**: Transformers.js manages IndexedDB automatically
- **Desktop cache**: Rust downloads to `app_data_dir/models/` via `ai/download.rs`
- **Model host**: configurable via `VITE_MODEL_HOST_URL` env var (defaults to Hugging Face Hub)

## Capability detection

`capabilities.js` probes the device and returns an `AICapabilities` object:

```js
{
  canRunClassification: true,        // Always true (WASM fallback)
  canRunGenerative: true,            // Depends on device
  classificationBackend: 'webgpu',   // 'webgpu' | 'wasm' | 'tauri-ort'
  generativeBackend: 'apple-foundation-models',
  hasWebGPU: true,
  deviceMemory: 16,                  // navigator.deviceMemory (0 if unknown)
  hardwareConcurrency: 10,
  isDesktop: true,                   // Tauri detected
  hasAppleFoundationModels: true,    // macOS 26+ check via Rust command
}
```

`detectCapabilitiesFromEnv()` accepts injected values for testing.

`matching.js` maps capabilities to backend decisions with human-readable reasoning strings.

## File map

```
ui/web/src/lib/ai/
├── index.js                    — Barrel exports for both tiers
├── capabilities.js             — Device probing + AICapabilities type
├── matching.js                 — Progressive backend selection
├── models.js                   — Model registry (repos, sizes, quantization)
├── modelManager.js             — Download, cache, consent, removal
├── inference.js                — Tier A API (routes to worker, Apple Intelligence, or native ONNX)
├── inference.worker.js         — Web Worker for Transformers.js
├── useAIClassification.js      — React hook for per-message classification
├── generative/
│   ├── index.js                — Tier B API (initializeGenerative, summarizeThread, etc.)
│   ├── webllmProvider.js       — Browser WebGPU LLM provider
│   ├── webllm.worker.js        — Web Worker for @mlc-ai/web-llm
│   └── tauriProvider.js        — Tauri invoke wrapper for Rust commands
└── __tests__/
    ├── capabilities.test.js    — 9 tests: all device combinations
    ├── matching.test.js        — 12 tests: every backend path + Tier B scaffold
    ├── models.test.js          — 7 tests: registry validation, size bounds
    ├── modelManager.test.js    — 6 tests: consent, status, removal
    ├── inference.test.js       — 7 tests: input validation, graceful degradation
    └── generative.test.js      — 5 tests: initial state, degradation, no-network

ui/web/src/components/
├── AIBadge/                    — Inline sentiment/intent badge
├── AISetup/                    — Setup/consent flow (multi-phase)
├── AIOnboardingModal/          — First-run modal wrapper
├── AISummaryPanel/             — Context sidebar summary (auto-trigger + cache)
├── AIInsightsPanel/            — Context sidebar sentiment/intent
├── SmartReplyBar/              — Reply suggestion chips
└── SummarizeButton/            — Thread summarize button

ui/web/src/pages/settings/
├── AIFeaturesSettings.jsx      — Toggle, model status, generative section
└── AIFeaturesSettings.module.css

ui/desktop/src-tauri/src/ai/
├── mod.rs
├── commands.rs                 — Tauri commands: check, download, remove, warmup, infer
├── generative_commands.rs      — Tauri commands: initialize, summarize, smart_replies, generate
├── apple_bridge.rs             — Swift subprocess manager (JSON over stdin/stdout)
├── native_llm.rs               — llama.cpp sidecar (HTTP, model download)
├── download.rs                 — Model file download + disk usage
└── inference.rs                — native ONNX Runtime engine: sessions + tokenizers,
                                   sentiment / zero-shot intent / embeddings (8 logic tests)

ui/desktop/src-tauri/tests/
└── ai_inference.rs             — model-backed ONNX integration tests (4, #[ignore]d)

ui/desktop/src-tauri/swift-bridge/
├── Package.swift               — Swift 6.2, macOS 26 target
├── FoundationModelsBridge.entitlements
└── Sources/FoundationModelsBridge/
    └── main.swift              — Foundation Models CLI (check, generate, summarize, smart_replies)
```

## Tests

Run from `ui/web/`:

```sh
npx vitest run --project unit     # 50 JS tests (6 files)
```

Run from `ui/desktop/src-tauri/`:

```sh
cargo test --lib                              # fast unit tests, incl. 8 Tier A logic tests
cargo test --test ai_inference -- --ignored   # model-backed ONNX tests (downloads ~180MB)
```

The model-backed tests (`tests/ai_inference.rs`) load the real quantized models and assert sentiment polarity, intent distribution + directionality, and normalized embeddings with sensible cosine similarity. They're `#[ignore]`d for the fast pass; CI runs them against a cached model dir (`INBOX2_AI_MODELS_DIR`), mirroring how the IMAP integration tests run against GreenMail. Set `INBOX2_AI_MODELS_DIR` to reuse a populated dir and skip the download.

Key test assertions:
- Every capability combination maps to the documented backend
- Classification returns null (not error) when AI is disabled — app fully functional without AI
- No outbound network requests during inference (only during one-time model download)
- Native ONNX zero-shot intent matches the Transformers.js algorithm (entailment logit, softmax across labels)
- Embeddings are correct-dimensioned (384) and L2-normalized
- Model removal clears consent + cache

## TTS break-in (iOS/Android)

Every TTS surface arms the shared `KeywordSpotter` (iOS) / `BargeInListener` (Android) **before** speech starts, so a spoken stop-word halts the voice without a tap. The spotter captures through the voice-processing I/O unit so AEC strips the app's own voice from the mic.

**Deliberate exception — read-aloud (`ReadAloudController`).** Reading a mail aloud plays on the plain playback-only session and arms the triage spotter only *after* speech ends (the 5 s "trash or archive?" window). Opening the mic during the read means switching to `.playAndRecord` with the voice-processing unit, and that path audibly degrades the synthesized voice (AEC + ducking mangled the read next to "Speak with" reading identical text). `KeywordSpotter` has no restricted-vocabulary mode that avoids the VP engine — any `start()` owns the input node and the record-capable session — so a cancel-word-only spotter during the read is not possible without the same quality hit. Tap the button/orb to stop mid-read; hands-free break-in resumes the moment the question is asked.

## Privacy guarantees

- All inference runs on-device. No email content is sent to any server.
- Model files are downloaded from Hugging Face Hub (or a configured mirror) — this is the only network traffic.
- Apple Intelligence processes text entirely on-device via the Foundation Models framework.
- The user explicitly opts in before any model is downloaded or any inference runs.
- "Skip" during setup is a first-class path — the app works fully without AI.
