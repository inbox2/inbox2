//! The on-device AI seam for the rule engine.
//!
//! The Tier-1 gate and the AI-backed built-in actions (auto-triage / auto-label)
//! need embeddings, intent, and sentiment from an on-device model. Rather than
//! depend on a concrete engine, core depends on this trait; each host injects an
//! implementation:
//!   - desktop: a wrapper over the ONNX Runtime `AIInferenceEngine`,
//!   - mobile: Apple Foundation Models / its own runtime,
//!   - `None`: gates and AI-backed actions **fail closed** (no dispatch).
//!
//! Every method is fail-soft: a missing/unloaded model returns `None`/`Err`/
//! `false` rather than panicking, so a rule never dispatches on a guess.

use async_trait::async_trait;

#[async_trait]
pub trait OnDeviceAi: Send + Sync {
    /// Whether the underlying models are loaded and ready to infer.
    async fn is_ready(&self) -> bool;

    /// Embed `text` with the on-device model (the same MiniLM the vector search
    /// uses). `None` when the model isn't loaded — callers treat that as
    /// fail-closed.
    async fn embed(&self, text: &str) -> Option<Vec<f32>>;

    /// Zero-shot intent label for `text` (e.g. "question", "request",
    /// "complaint"). `Err` when the engine is missing or its models aren't loaded.
    async fn intent(&self, text: &str) -> Result<String, String>;

    /// Whether `text` reads as negative sentiment. Fail-soft: `false` when the
    /// model can't run.
    async fn sentiment_negative(&self, text: &str) -> bool;
}
