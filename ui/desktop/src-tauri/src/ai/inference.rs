use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use serde::Serialize;

use ort::session::{Session, SessionInputValue};
use ort::value::Tensor;
use tokenizers::Tokenizer;

use crate::ai::download::models_dir;

/// Candidate intent labels — must match the browser worker / models.js exactly
/// so the native path produces the same classification contract.
pub const INTENT_LABELS: [&str; 6] = [
    "question",
    "request",
    "complaint",
    "FYI",
    "scheduling",
    "other",
];

/// Zero-shot hypothesis template — matches the Transformers.js default
/// (`"This example is {}."`) so entailment scores line up with the JS path.
const HYPOTHESIS_TEMPLATE: &str = "This example is {}.";

/// Max sequence length (tokens). The frontend already truncates to 512 chars;
/// we additionally cap token length to the BERT/DeBERTa context window.
const MAX_TOKENS: usize = 512;

/// Inference result for sentiment analysis.
#[derive(Debug, Serialize, Clone)]
pub struct SentimentResult {
    pub label: String,
    pub score: f32,
}

/// Inference result for intent classification.
#[derive(Debug, Serialize, Clone)]
pub struct IntentResult {
    pub label: String,
    pub score: f32,
    pub scores: HashMap<String, f32>,
}

/// Inference result for text embeddings.
#[derive(Debug, Serialize, Clone)]
pub struct EmbeddingResult {
    pub embedding: Vec<f32>,
    pub dimensions: usize,
}

/// A loaded ONNX model + its tokenizer and declared input names.
struct LoadedModel {
    session: Session,
    tokenizer: Tokenizer,
    /// The input names the ONNX graph declares (e.g. `input_ids`,
    /// `attention_mask`, and optionally `token_type_ids`). We only feed inputs
    /// the model actually expects.
    input_names: Vec<String>,
}

impl LoadedModel {
    /// Load a model + tokenizer from `{dir}/{model.onnx, tokenizer.json}`.
    fn load(dir: &Path) -> Result<Self, String> {
        let model_path = dir.join("model.onnx");
        let tokenizer_path = dir.join("tokenizer.json");

        let session = Session::builder()
            .map_err(|e| format!("session builder: {e}"))?
            .commit_from_file(&model_path)
            .map_err(|e| format!("load {}: {e}", model_path.display()))?;

        let tokenizer = Tokenizer::from_file(&tokenizer_path)
            .map_err(|e| format!("load {}: {e}", tokenizer_path.display()))?;

        let input_names = session
            .inputs()
            .iter()
            .map(|i| i.name().to_string())
            .collect();

        Ok(Self {
            session,
            tokenizer,
            input_names,
        })
    }

    /// Tokenize one or two text segments into (input_ids, attention_mask),
    /// truncated to MAX_TOKENS.
    fn tokenize(&self, a: &str, b: Option<&str>) -> Result<(Vec<i64>, Vec<i64>), String> {
        let encoding = match b {
            Some(b) => self
                .tokenizer
                .encode((a, b), true)
                .map_err(|e| format!("tokenize pair: {e}"))?,
            None => self
                .tokenizer
                .encode(a, true)
                .map_err(|e| format!("tokenize: {e}"))?,
        };
        let mut ids: Vec<i64> = encoding.get_ids().iter().map(|&x| x as i64).collect();
        let mut mask: Vec<i64> = encoding
            .get_attention_mask()
            .iter()
            .map(|&x| x as i64)
            .collect();
        if ids.len() > MAX_TOKENS {
            ids.truncate(MAX_TOKENS);
            mask.truncate(MAX_TOKENS);
        }
        Ok((ids, mask))
    }

    /// Build the named input tensors the session declares and run inference,
    /// returning the first output as (shape dims, flat f32 data).
    fn run(&mut self, ids: &[i64], mask: &[i64]) -> Result<(Vec<i64>, Vec<f32>), String> {
        let seq = ids.len();
        let mut inputs: Vec<(Cow<str>, SessionInputValue)> = Vec::with_capacity(3);
        for name in &self.input_names {
            let tensor = match name.as_str() {
                "input_ids" => Tensor::from_array(([1usize, seq], ids.to_vec())),
                "attention_mask" => Tensor::from_array(([1usize, seq], mask.to_vec())),
                "token_type_ids" => Tensor::from_array(([1usize, seq], vec![0i64; seq])),
                // Unknown optional input — skip; the model will use its default.
                _ => continue,
            }
            .map_err(|e| format!("tensor {name}: {e}"))?;
            inputs.push((Cow::Owned(name.clone()), SessionInputValue::from(tensor)));
        }

        let outputs = self
            .session
            .run(inputs)
            .map_err(|e| format!("inference: {e}"))?;
        let (shape, data) = outputs[0]
            .try_extract_tensor::<f32>()
            .map_err(|e| format!("extract output: {e}"))?;
        let dims: Vec<i64> = shape.iter().copied().collect();
        Ok((dims, data.to_vec()))
    }
}

/// The AI inference engine: holds ONNX Runtime sessions + tokenizers for the
/// three Tier A models (sentiment, intent, embeddings) and runs classification
/// natively, matching the browser Transformers.js contract.
pub struct AIInferenceEngine {
    app_data_dir: Arc<Path>,
    sentiment: Option<LoadedModel>,
    intent: Option<LoadedModel>,
    embeddings: Option<LoadedModel>,
    /// Sentiment labels in output-index order (from config.json id2label).
    sentiment_labels: Vec<String>,
    /// Index of the "entailment" class in the NLI model's output.
    intent_entailment_idx: usize,
    initialized: bool,
}

impl AIInferenceEngine {
    pub fn new(app_data_dir: &Path) -> Self {
        Self {
            app_data_dir: Arc::from(app_data_dir),
            sentiment: None,
            intent: None,
            embeddings: None,
            sentiment_labels: vec!["NEGATIVE".to_string(), "POSITIVE".to_string()],
            intent_entailment_idx: 2,
            initialized: false,
        }
    }

    /// Load all ONNX sessions + tokenizers into memory. Call during warmup.
    pub fn warmup(&mut self) -> Result<(), String> {
        let dir = models_dir(&self.app_data_dir);
        if !dir.exists() {
            return Err("Models directory does not exist".to_string());
        }

        let sentiment_dir = dir.join("sentiment");
        let intent_dir = dir.join("intent");
        let embeddings_dir = dir.join("embeddings");

        self.sentiment = Some(LoadedModel::load(&sentiment_dir)?);
        self.intent = Some(LoadedModel::load(&intent_dir)?);
        self.embeddings = Some(LoadedModel::load(&embeddings_dir)?);

        // Resolve label orderings from each model's config.json.
        self.sentiment_labels = parse_id2label(&sentiment_dir.join("config.json"))
            .unwrap_or_else(|_| vec!["NEGATIVE".to_string(), "POSITIVE".to_string()]);
        let nli_labels = parse_id2label(&intent_dir.join("config.json")).unwrap_or_default();
        self.intent_entailment_idx = nli_labels
            .iter()
            .position(|l| l.eq_ignore_ascii_case("entailment"))
            .unwrap_or(2);

        self.initialized = true;
        Ok(())
    }

    /// Run sentiment analysis on input text.
    pub fn run_sentiment(&mut self, text: &str) -> Result<SentimentResult, String> {
        if !self.initialized {
            return Err("Engine not initialized — call warmup() first".to_string());
        }
        let labels = self.sentiment_labels.clone();
        let model = self
            .sentiment
            .as_mut()
            .ok_or("sentiment model not loaded")?;
        let (ids, mask) = model.tokenize(text, None)?;
        let (_dims, logits) = model.run(&ids, &mask)?;
        let probs = softmax(&logits);
        let (best, &score) = probs
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
            .ok_or("empty sentiment output")?;
        let label = labels
            .get(best)
            .cloned()
            .unwrap_or_else(|| "POSITIVE".to_string());
        Ok(SentimentResult { label, score })
    }

    /// Run zero-shot intent classification via NLI entailment.
    ///
    /// For each candidate label we form the hypothesis "This example is {label}.",
    /// run the NLI model on (text, hypothesis), take the entailment logit, then
    /// softmax those logits across all labels (multi_label = false), matching the
    /// Transformers.js zero-shot pipeline.
    pub fn run_intent(&mut self, text: &str) -> Result<IntentResult, String> {
        if !self.initialized {
            return Err("Engine not initialized — call warmup() first".to_string());
        }
        let entail_idx = self.intent_entailment_idx;
        let model = self.intent.as_mut().ok_or("intent model not loaded")?;

        let mut entail_logits = Vec::with_capacity(INTENT_LABELS.len());
        for label in INTENT_LABELS {
            let hypothesis = HYPOTHESIS_TEMPLATE.replace("{}", label);
            let (ids, mask) = model.tokenize(text, Some(&hypothesis))?;
            let (_dims, logits) = model.run(&ids, &mask)?;
            let logit = logits
                .get(entail_idx)
                .copied()
                .ok_or("NLI output missing entailment logit")?;
            entail_logits.push(logit);
        }

        let probs = softmax(&entail_logits);
        let mut scores = HashMap::new();
        for (i, label) in INTENT_LABELS.iter().enumerate() {
            scores.insert(label.to_string(), probs[i]);
        }
        let (best, &score) = probs
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
            .ok_or("empty intent output")?;
        Ok(IntentResult {
            label: INTENT_LABELS[best].to_string(),
            score,
            scores,
        })
    }

    /// Generate a mean-pooled, L2-normalized text embedding.
    pub fn run_embedding(&mut self, text: &str) -> Result<EmbeddingResult, String> {
        if !self.initialized {
            return Err("Engine not initialized — call warmup() first".to_string());
        }
        let model = self
            .embeddings
            .as_mut()
            .ok_or("embeddings model not loaded")?;
        let (ids, mask) = model.tokenize(text, None)?;
        let (dims, hidden) = model.run(&ids, &mask)?;
        // Expected output shape: [1, seq, hidden_size].
        let seq = mask.len();
        let hidden_size = hidden.len().checked_div(seq).unwrap_or(0);
        if hidden_size == 0 {
            return Err(format!("unexpected embedding output shape: {dims:?}"));
        }
        let embedding = mean_pool_normalize(&hidden, &mask, hidden_size);
        Ok(EmbeddingResult {
            dimensions: embedding.len(),
            embedding,
        })
    }

    pub fn is_ready(&self) -> bool {
        self.initialized
    }
}

/// Numerically stable softmax.
fn softmax(logits: &[f32]) -> Vec<f32> {
    if logits.is_empty() {
        return Vec::new();
    }
    let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let exps: Vec<f32> = logits.iter().map(|&x| (x - max).exp()).collect();
    let sum: f32 = exps.iter().sum();
    if sum == 0.0 {
        return vec![0.0; logits.len()];
    }
    exps.iter().map(|&x| x / sum).collect()
}

/// Mean-pool token hidden states using the attention mask, then L2-normalize.
fn mean_pool_normalize(hidden: &[f32], mask: &[i64], hidden_size: usize) -> Vec<f32> {
    let mut pooled = vec![0f32; hidden_size];
    let mut count = 0f32;
    for (t, &mask_val) in mask.iter().enumerate() {
        let m = mask_val as f32;
        if m == 0.0 {
            continue;
        }
        count += m;
        let base = t * hidden_size;
        for d in 0..hidden_size {
            pooled[d] += hidden[base + d] * m;
        }
    }
    if count > 0.0 {
        for v in pooled.iter_mut() {
            *v /= count;
        }
    }
    let norm = pooled.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for v in pooled.iter_mut() {
            *v /= norm;
        }
    }
    pooled
}

/// Parse a HuggingFace `config.json` `id2label` map into a label vector ordered
/// by integer index.
fn parse_id2label(config_path: &Path) -> Result<Vec<String>, String> {
    let text =
        fs::read_to_string(config_path).map_err(|e| format!("read config.json: {e}"))?;
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("parse config.json: {e}"))?;
    let map = value
        .get("id2label")
        .and_then(|m| m.as_object())
        .ok_or("config.json has no id2label")?;
    let mut pairs: Vec<(usize, String)> = map
        .iter()
        .filter_map(|(k, v)| {
            let idx = k.parse::<usize>().ok()?;
            let label = v.as_str()?.to_string();
            Some((idx, label))
        })
        .collect();
    pairs.sort_by_key(|(i, _)| *i);
    Ok(pairs.into_iter().map(|(_, label)| label).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn softmax_sums_to_one() {
        let p = softmax(&[1.0, 2.0, 3.0]);
        let sum: f32 = p.iter().sum();
        assert!((sum - 1.0).abs() < 1e-5);
        // Monotonic: larger logit -> larger prob.
        assert!(p[2] > p[1] && p[1] > p[0]);
    }

    #[test]
    fn softmax_empty_and_degenerate() {
        assert!(softmax(&[]).is_empty());
        let p = softmax(&[5.0]);
        assert_eq!(p.len(), 1);
        assert!((p[0] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn mean_pool_respects_mask_and_normalizes() {
        // 2 tokens, hidden_size 2. Second token masked out.
        let hidden = vec![3.0, 4.0, 100.0, 100.0];
        let mask = vec![1i64, 0];
        let out = mean_pool_normalize(&hidden, &mask, 2);
        // Only first token counts: (3,4) normalized -> (0.6, 0.8).
        assert!((out[0] - 0.6).abs() < 1e-5);
        assert!((out[1] - 0.8).abs() < 1e-5);
        let norm = (out[0] * out[0] + out[1] * out[1]).sqrt();
        assert!((norm - 1.0).abs() < 1e-5);
    }

    #[test]
    fn parse_id2label_orders_by_index() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        std::fs::write(
            &path,
            r#"{"id2label":{"2":"entailment","0":"contradiction","1":"neutral"}}"#,
        )
        .unwrap();
        let labels = parse_id2label(&path).unwrap();
        assert_eq!(labels, vec!["contradiction", "neutral", "entailment"]);
        assert_eq!(
            labels.iter().position(|l| l == "entailment"),
            Some(2)
        );
    }

    #[test]
    fn intent_labels_match_contract() {
        // Guard against drift from the JS/models.js label set.
        assert_eq!(
            INTENT_LABELS,
            ["question", "request", "complaint", "FYI", "scheduling", "other"]
        );
    }

    #[test]
    fn engine_not_ready_before_warmup() {
        let dir = tempfile::tempdir().unwrap();
        let engine = AIInferenceEngine::new(dir.path());
        assert!(!engine.is_ready());
    }

    #[test]
    fn warmup_fails_without_model_dir() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = AIInferenceEngine::new(dir.path());
        assert!(engine.warmup().is_err());
    }

    #[test]
    fn inference_fails_before_warmup() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = AIInferenceEngine::new(dir.path());
        assert!(engine.run_sentiment("hello").is_err());
        assert!(engine.run_intent("hello").is_err());
        assert!(engine.run_embedding("hello").is_err());
    }
}
