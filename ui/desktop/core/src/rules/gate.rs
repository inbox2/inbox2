// Tier-1 on-device gate — the cheap LLM-ish confirmation that runs after a Tier-0
// static match and before dispatching an agent (docs/Agentic-Filters.md §1).
//
// Implementation: embedding similarity. We embed the message and the rule's gate
// phrase with the same on-device MiniLM model the vector search uses (always
// available, no Apple Intelligence required) and pass when cosine ≥ threshold.
// The runner caches each rule's phrase embedding across a scan; this module just
// parses the gate config and embeds text. Cosine comparison lives host-side (the
// desktop runner uses `vector::search`).

use super::ai::OnDeviceAi;

#[derive(Debug, Clone, serde::Deserialize)]
pub struct AiGate {
    /// A natural-language description of what should match, e.g.
    /// "an invoice or bill requesting payment".
    pub phrase: String,
    #[serde(default = "default_threshold")]
    pub threshold: f32,
}

fn default_threshold() -> f32 {
    0.30
}

/// Parse an `ai_gate` JSON value into a gate, or None when absent/empty (→ Tier-0 only).
pub fn parse_gate(value: Option<&serde_json::Value>) -> Option<AiGate> {
    let value = value?;
    serde_json::from_value::<AiGate>(value.clone())
        .ok()
        .filter(|g| !g.phrase.trim().is_empty())
}

/// Embed text with the on-device model. Returns `None` when the model isn't loaded
/// — callers treat that as **fail-closed** (a gated rule never dispatches without
/// its gate).
pub async fn embed_text(ai: &dyn OnDeviceAi, text: &str) -> Option<Vec<f32>> {
    ai.embed(text).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_gate_handles_absent_and_empty() {
        assert!(parse_gate(None).is_none());
        assert!(parse_gate(Some(&serde_json::json!({ "phrase": "  " }))).is_none());
        let g = parse_gate(Some(&serde_json::json!({ "phrase": "an invoice" }))).unwrap();
        assert_eq!(g.phrase, "an invoice");
        assert_eq!(g.threshold, 0.30);
        let g2 = parse_gate(Some(&serde_json::json!({ "phrase": "x", "threshold": 0.5 }))).unwrap();
        assert_eq!(g2.threshold, 0.5);
    }
}
