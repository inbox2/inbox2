//! Adapts the desktop's ONNX `AIInferenceEngine` to core's host-agnostic
//! [`OnDeviceAi`] seam, so the (now core) rule engine's Tier-1 gate and AI-backed
//! actions can run without core depending on ONNX Runtime. Mobile will provide its
//! own `OnDeviceAi` implementation (Apple Foundation Models / its own runtime).

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::Mutex;

use inbox2_core::rules::OnDeviceAi;

use crate::ai::inference::AIInferenceEngine;

pub struct InferenceAi(pub Arc<Mutex<AIInferenceEngine>>);

#[async_trait]
impl OnDeviceAi for InferenceAi {
    async fn is_ready(&self) -> bool {
        self.0.lock().await.is_ready()
    }

    async fn embed(&self, text: &str) -> Option<Vec<f32>> {
        let mut eng = self.0.lock().await;
        if !eng.is_ready() {
            return None;
        }
        eng.run_embedding(text).ok().map(|r| r.embedding)
    }

    async fn intent(&self, text: &str) -> Result<String, String> {
        let mut eng = self.0.lock().await;
        if !eng.is_ready() {
            return Err("on-device AI models not loaded".into());
        }
        eng.run_intent(text).map(|r| r.label)
    }

    async fn sentiment_negative(&self, text: &str) -> bool {
        let mut eng = self.0.lock().await;
        eng.run_sentiment(text)
            .map(|s| s.label.eq_ignore_ascii_case("negative"))
            .unwrap_or(false)
    }
}
