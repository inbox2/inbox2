use std::sync::Arc;
use tokio::sync::Mutex;

use crate::ai::inference::AIInferenceEngine;

/// Wrapper around the AI inference engine for embedding operations.
///
/// Provides a batch interface and handles engine readiness checks.
/// The underlying ONNX engine is stubbed — once ORT is integrated,
/// this module will produce real 384-dim embeddings.
pub struct Embedder {
    engine: Arc<Mutex<AIInferenceEngine>>,
}

impl Embedder {
    pub fn new(engine: Arc<Mutex<AIInferenceEngine>>) -> Self {
        Self { engine }
    }

    /// Embed a single text string. Returns a 384-dim f32 vector.
    pub async fn embed(&self, text: &str) -> Result<Vec<f32>, String> {
        let mut engine = self.engine.lock().await;
        if !engine.is_ready() {
            return Err("Embedding engine not ready — models not loaded".to_string());
        }
        let result = engine.run_embedding(text)?;
        Ok(result.embedding)
    }

    /// Embed a batch of texts. Returns one vector per input.
    /// Processes sequentially through the engine (ORT doesn't support
    /// dynamic batching without padding at this model size).
    pub async fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let mut engine = self.engine.lock().await;
        if !engine.is_ready() {
            return Err("Embedding engine not ready — models not loaded".to_string());
        }
        let mut results = Vec::with_capacity(texts.len());
        for text in texts {
            let result = engine.run_embedding(text)?;
            results.push(result.embedding);
        }
        Ok(results)
    }

    /// Check if the underlying engine has loaded models and is ready.
    pub async fn is_ready(&self) -> bool {
        let engine = self.engine.lock().await;
        engine.is_ready()
    }

    /// Embedding dimensions (fixed for all-MiniLM-L6-v2).
    pub fn dimensions(&self) -> usize {
        384
    }
}
