# AI Lanes, Prompt Templates & the Triage Eval Harness

How the AI model lanes are unified across desktop/iOS/Android, how the LLM
prompts are externalized into a user-editable template file, and how triage
quality is measured with the eval harness (CLI, desktop Triage Lab, mobile FFI).

> Since 2026-09-19 triage **classification** (label, priority, Space) is Jev,
> TypeSafe's hosted model — contract in [Triage.md](Triage.md). The lanes below
> still write the triage **summaries** and run the Bridge; they no longer pick
> labels or Spaces.

See also: [Client-AI.md](Client-AI.md) (the desktop Tier A/B inference stack and
Apple FM bridge mechanics) and the triage worker internals in
`ui/desktop/core/src/ai_worker.rs`.

## Unified model lanes

Every Bridge capability (TTS / STT / NLU) routes through three lanes — `native`,
`free`, `openai` — declared in the shared manifest
`ui/desktop/core/src/bridge/models/models.json` and resolved by the pure
`effective_lane()` rule (`bridge/models/mod.rs`). The **NLU free lane is the same
checkpoint on every platform**: Qwen2.5-1.5B-Instruct (Apache-2.0, ungated — no
HuggingFace token anywhere):

| Platform | NLU native | NLU free (same weights everywhere) | NLU cloud |
|---|---|---|---|
| iOS | Apple Foundation Models (iOS 26+, AI enabled) | `qwen2.5-1.5b-instruct-q8` — LiteRT `.task`, 1.6 GB, MediaPipe | OpenAI `gpt-4o-mini` |
| Android | — (free lane *is* on-device) | `qwen2.5-1.5b-instruct-q8` — LiteRT `.task` | OpenAI |
| Desktop | Apple FM via Swift subprocess (macOS 26+) | `qwen2.5-1.5b-instruct-gguf` — Q4_K_M GGUF, 1.1 GB, llama-server sidecar | OpenAI |

The NLU free lane additionally carries an opt-in **variant**: Gemma 3 1B — ~2x
smaller and faster than Qwen (a real difference for brief prewarming on phones),
but English-only and license-gated on mobile. Manifest order is the default
order (Qwen first); `Manifest::entries_for` lists every variant, the free lane
counts as installed when ANY variant is, and the host persists which one to run
(`inbox2_nlu_free_model` on iOS/desktop, `free_nlu_model` in Android prefs):

| Platform | Gemma variant | Size | Gated? |
|---|---|---|---|
| iOS / Android | `gemma3-1b-it-int4` — LiteRT `.task` (q4_block32, ekv4096) | 722 MB | Yes — needs the HF token (Gemma license accepted) |
| Desktop | `gemma3-1b-it-gguf` — Q4_K_M GGUF from `ggml-org` | 806 MB | No — anonymous download |

Mechanics worth knowing:

- A (capability × lane) pair may carry **per-platform artifacts** of the same
  weights — `Manifest::entry_for(cap, lane, os)` resolves the platform's entry
  (mobile `.task` vs desktop GGUF). `Engine::LlamaCpp` marks the sidecar entry.
- The desktop sidecar (`src-tauri/src/ai/native_llm.rs`) derives its model
  id/URL/filename from the manifest entry (`MANIFEST_MODEL_ID`) — desktop and
  mobile can't drift onto different weights without a manifest edit.
- **Chat template**: per-model, formatted app-side on mobile (`BridgeLLM.swift` /
  `BridgeLLM.kt` — the `.task` bundles embed the stop token but NOT the turn
  markers). Qwen uses ChatML (`<|im_start|>system…<|im_end|>…`) with a real
  system turn; Gemma uses `<start_of_turn>` markers and has no system role, so
  the system text is folded into the user turn. Desktop needs nothing:
  llama-server's `/v1/chat/completions` applies the GGUF-embedded template.
- **Sampling is pinned identically everywhere**: temperature 0.3, top-k 40,
  512 output tokens, 4096 total context — `bridge::ON_DEVICE_*` constants in
  `bridge/mod.rs`. The desktop sidecar and the eval CLI read them directly; the
  mobile LiteRT engines mirror them as literals (one fresh MediaPipe session
  per call, so no cross-call context accumulation). Change them together.
- Why Qwen is the default: the 1B Gemma is **English-only** (the "140
  languages" claim starts at 4B), misread Dutch mail, and had the worst
  small-model JSON-schema compliance — Qwen also downloads anonymously. Gemma
  remains available as the speed-over-quality variant; picking it on mobile
  surfaces the HuggingFace-token field (its repo is gated; the token rides the
  core downloader's bearer header via `set_hf_token`). `BridgeLLM` runs the
  chosen variant and falls back to the other installed one, so deleting a model
  never silently kills the lane.

## Prompt templates (`prompts.toml`)

All LLM prompt texts live in `ui/desktop/core/src/bridge/prompts.toml`, embedded
at compile time as the defaults. Sections: `[chat]`, `[brief]`, `[tomorrow]`,
`[week]`, `[draft_reply]`, `[summary]` (the triage worker's `{"medium","short","title"}`
summaries + Lore to-do title; an override without `"title"` leaves it null), `[intent]`, `[smart_replies]`, `[summarize]`, plus `[openai]
chat_model`. Placeholders substituted at render time:

- `{now}` — the spelled-out local clock (`[chat]`, `[intent]`).
- `{intents}` — the intent catalog (`[intent]`; required in an override).

The old `[triage]` section (label + summaries in one prompt, with a `{labels}`
placeholder) is retired: an override file that still carries it loads fine and
the section is ignored with a log line. Labels are edited as data now (engine
setting `triage_labels`, see [Triage.md](Triage.md)).

Override resolution (`bridge/prompts.rs`):

- `prompts::set_overrides(Some(toml))` validates, then installs; sections absent
  from the override keep their embedded defaults. Rejected input (bad TOML,
  unknown-section typos via `deny_unknown_fields`, an `[intent]` without
  `{intents}`) **changes nothing** — a broken edit can never take triage or the
  Bridge down.
- Desktop loads `<app data dir>/prompts.toml` at startup (`setup.rs`,
  `init_ai_subsystems`) and edits it live via the `prompts_get` / `prompts_set`
  / `prompts_reset` Tauri commands (`ai/prompt_commands.rs`) — `prompts_set`
  validates before persisting and applies in-process, no restart.
- Mobile: a per-section editor under Settings → Dev mode (iOS
  `PromptTemplatesView`, Android `DevScreen`) — instead of one big TOML, each
  template section (Voice chat, Daily brief, …, Triage, OpenAI model) gets its
  own editor (the Triage section is now Summary). The core does all the TOML
  work over FFI:
  `prompt_sections(toml?)` returns the per-section view (override text where
  edited, defaults elsewhere) and `build_prompt_overrides(sections)` rebuilds
  a validated file carrying ONLY the sections that differ from the defaults
  (empty result = no overrides → the host clears + deletes its file). The
  host persists the built text at `<data dir>/prompts.toml` and re-installs
  it at launch via `set_prompt_overrides`; an invalid file is logged and
  skipped, never fatal.

## Space sorting (local channels on the org Spaces board)

The triage worker can additionally file local-channel threads into the org's
Spaces — the same buckets MX mail goes into — writing `conversations.space_slug`
in the local SQLite store. It rides on the same Jev call as the label and
priority (the `space` question, `docs/Triage.md`), so it needs a Jev key. Off by
default (`space_classify_enabled` engine setting; desktop toggle in Settings →
Triage & sync → "Sort into your org's Spaces").

- **Taxonomy** — the org's classifiable spaces, pushed by every client as the
  `space_taxonomy` engine setting (`set_space_taxonomy` Tauri command/FFI):
  JSON `[{slug,name,description,not_for},…]`, legacy `[["slug","description"],…]`
  still accepted. No taxonomy pushed = no space question. A `no_match` answer or
  one under probability 0.5 files into the `triage` holding pen. Spam is never
  asked (Rspamd owns spam).
- **Backfill** — enabling the toggle enqueues every in-window thread with no
  space (`backfill_space_queue`). Already-triaged threads take the worker's
  **fast path** (`process()` checks `triage_meta`: staleness anchor still
  matches → no summary re-run, one Jev call for what's missing). A Jev key
  arriving later uses the same path (`requeue_for_jev`).
- **Events** — each routed thread emits `space-updated`
  (`{conversationKey, slug}`), bridged by web `sync-manager.js`.
- **Dashboard overlay** — on desktop, the Spaces board's **Mine** view
  (`SpaceDashboard.jsx`, data from `useSpaceBoard` + `lib/spaceBoard.js`)
  merges the viewer's local threads (read straight from SQLite, every thread
  per `space_slug` with its label + priority) with their assigned MX threads,
  plus the device's personal Spaces (`get_personal_spaces`). The **Team** view
  is MX only. Browser/other members see only the MX data —
  the classifications never reach inbox2's servers (only the space *taxonomy*
  comes down from the API). The thread text does go to TypeSafe for the Jev call.

## Triage eval harness

`ui/desktop/core/src/triage_eval.rs` scores fixture threads through the **exact
production triage path**: each case is seeded into an ephemeral in-memory
`SyncStore` and read back via `conversation_triage_input()` (so the
deterministic `detect_label` SQL, thread-text assembly, and body caps run as in
production); then, with a Jev key, the worker's own `ai_worker::jev_classify()`
runs (label when no rule fired, priority always). A score measured here is what
the app would produce.

### Fixture format

`core/fixtures/triage-eval.json` is the starter set (the rule paths, the
original 8 labels plus `payment_due`/`receipt`, Dutch cases) and is embedded as `triage_eval::STARTER_FIXTURES`. Either a
top-level array or `{"cases": [...]}`:

```json
{
  "name": "dutch-invoice",
  "subject": "Uw rekening van Maxim Dental B.V.",
  "expected": "action_required",
  "messages": [
    { "from": "Infomedics <noreply@infomedics.nl>",
      "message_id": "<x@infomedics.nl>",
      "body": "U heeft 30 dagen om te betalen. Bedrag: € 32,42.",
      "html": null,
      "sent_by_owner": false }
  ]
}
```

`expected` is optional (omit to just observe) and must name a label in the
label set (built-ins, plus custom ones in the Triage Lab). `message_id` feeds
the ESP-domain rules; `html` is where unsubscribe footers usually live;
`sent_by_owner` drives the direction (`sent` vs `received` in the Jev state).
Per-case results report `predicted`, `priority`, `source` (`rule:*`, `jev:*`,
`rule:*+jev:*`), the raw `signals` that fired, the deterministic summaries, and
`pass`.

### Three front-ends, one runner

- **CLI** — `cd ui/desktop/core && cargo run --bin triage-eval -- fixtures/triage-eval.json`
  - rules-only by default (ambiguous cases report "no Jev key");
  - `--jev-key …` (or `$TYPESAFE_API_KEY`) = the Jev lane, built-in labels;
  - `--json` for diffable reports; non-zero exit on failures/errors, so it can
    gate CI.
- **Desktop Triage Lab** — `/triage-lab` (command palette → "Open Triage Lab",
  desktop only). Fixtures editor (⌘↵ runs) → per-case verdicts with provenance
  and signals. Uses the engine's live Jev key and label set.
- **Mobile FFI** — `run_triage_eval(fixtures_json)` on `InboxEngine` runs the
  same suite with the engine's key and labels and returns the `EvalReport` JSON;
  `default_eval_fixtures()` seeds a debug screen.

### Workflow: tuning a misclassification

1. Find a wrongly-triaged thread; `conversations.triage_source` /
   `triage_signals` say which stages ran and which raw signals fired.
   `triage_source` is `+`-joined: `rule:<name>` (deterministic label),
   `jev:<model>` (Jev answered), `model:openai:<chat-model>` /
   `model:on_device:<manifest-id|apple-fm>` (who wrote the summaries), e.g.
   `rule:action+jev:jev-1.13.0+model:openai:gpt-4o-mini`. `fallback:exhausted`
   marks a poison thread given the rule label or `fyi`.
2. Add it (anonymized) as a fixture case with the label it *should* get.
3. Rules bug → tune `detect_label` in `sync/store/ai_triage.rs`. Jev miss → the
   label's description / `not_for` is the lever (built-in texts are
   parity-locked with Rails: change both sides + the fixture), or a custom label.
4. Keep the case in the fixture file — it's now a regression test
   (`triage-eval` exits non-zero on regressions).

Baselines on the starter set (14 cases): the old OpenAI prompt lane scored
13/14 (missed `needs_answer_other`). Jev `jev-1.13.0` (2026-09-19) scores 13/14:
it gets `needs_answer_other` right and labels `dutch-personal-question` (a
notary asking for a copy of your ID this week) `action_required` instead of
`needs_answer` — defensible, since "upload a requested file" is in the
`action_required` description.
