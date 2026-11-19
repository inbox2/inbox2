//! The Bridge — the shared LLM brief + agent layer.
//!
//! Prompts, the OpenAI client, the daily-brief assembler, the agent tool catalog,
//! and the turn orchestration all live here so desktop, CLI, and mobile share one
//! implementation. Generation routes between a frontier model (OpenAI, in-Rust) and
//! an on-device model (Apple Foundation Models / a local sidecar) that the host
//! injects via the [`LocalGenerator`] trait.

pub mod agent;
pub mod brief;
pub mod email_voice;
pub mod intent;
pub mod models;
pub mod openai;
pub mod prompts;
pub mod tools;

use async_trait::async_trait;

/// Sampling settings for FREE-LANE on-device generation, shared by every
/// platform's engine so the same input scores the same everywhere: the desktop
/// llama-server sidecar reads these directly; the mobile LiteRT engines
/// (`BridgeLLM.swift` / `BridgeLLM.kt`) read them over the FFI via the
/// `on_device_*` exports in `ffi.rs`.
///
/// Low temperature: triage wants deterministic JSON, not creative prose.
pub const ON_DEVICE_TEMPERATURE: f32 = 0.3;
/// MediaPipe's default top-k, pinned explicitly so a MediaPipe default change
/// can't silently diverge mobile from desktop.
pub const ON_DEVICE_TOP_K: i32 = 40;
/// Output-token budget for one generation (the sidecar's `max_tokens`).
pub const ON_DEVICE_MAX_OUTPUT_TOKENS: u32 = 512;
/// Total context budget, input + output: the sidecar's `--ctx-size` and mobile
/// LiteRT's `maxTokens`. Matches the ekv4096 KV cache of the Qwen `.task` bundle.
pub const ON_DEVICE_CONTEXT_TOKENS: u32 = 4096;

/// Host-injected on-device text generation (Apple Foundation Models on Apple
/// platforms, a local sidecar on desktop, or `None`). Mirrors the seam that
/// [`crate::rules::ai::OnDeviceAi`] provides for classification. Fail-soft: return
/// `Err` when unavailable and the caller falls back.
#[async_trait]
pub trait LocalGenerator: Send + Sync {
    /// Whether on-device generation is usable right now.
    async fn is_available(&self) -> bool;
    /// Generate a completion for `system` + `user`. `model` is the engine the host
    /// should run (`BridgeConfig::on_device_model` — a manifest id or `apple-fm`);
    /// `None` lets the host route by its own preference.
    async fn generate(&self, system: String, user: String, model: Option<String>) -> Result<String, String>;
    /// Generate a structured intent JSON (see [`crate::bridge::intent`]). Hosts that
    /// support guided generation (Apple Foundation Models `@Generable`) override this
    /// for guaranteed schema-valid output; the default falls back to plain text-JSON
    /// generation, which the tolerant parser handles.
    async fn generate_intent(&self, system: String, user: String, model: Option<String>) -> Result<String, String> {
        self.generate(system, user, model).await
    }
}
