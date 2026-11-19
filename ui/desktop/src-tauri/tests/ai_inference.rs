//! Model-backed integration tests for the native ONNX Runtime Tier A engine.
//!
//! These verify that the real quantized ONNX models load and run via `ort`,
//! and that outputs match the contract the browser Transformers.js path
//! produces (sentiment label/score, zero-shot intent over the 6 candidate
//! labels, mean-pooled + L2-normalized 384-dim embeddings).
//!
//! They are `#[ignore]`d by default: each run downloads ~180 MB of models from
//! HuggingFace on first use (cached afterwards) and needs network access, so
//! they don't belong in the fast unit-test pass.
//!
//! Run locally:
//!   cargo test --test ai_inference -- --ignored --nocapture
//!
//! Re-use a pre-populated model dir (skips download):
//!   INBOX2_AI_MODELS_DIR=/path/to/appdata cargo test --test ai_inference -- --ignored
//!
//! The dir layout matches the app: `{INBOX2_AI_MODELS_DIR}/models/{key}/{model.onnx,tokenizer.json,config.json}`.

use std::path::{Path, PathBuf};

use app_lib::ai::inference::AIInferenceEngine;

/// (key, HuggingFace repo) — mirrors download.rs / models.js.
const MODELS: &[(&str, &str)] = &[
    (
        "sentiment",
        "Xenova/distilbert-base-uncased-finetuned-sst-2-english",
    ),
    ("intent", "Xenova/nli-deberta-v3-xsmall"),
    ("embeddings", "Xenova/all-MiniLM-L6-v2"),
];

/// Download a file if it isn't already cached.
fn download_if_absent(dest: &Path, url: &str) {
    if dest.exists() && dest.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        return;
    }
    eprintln!("downloading {url}");
    let resp = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()
        .unwrap()
        .get(url)
        .send()
        .unwrap_or_else(|e| panic!("GET {url}: {e}"));
    assert!(resp.status().is_success(), "GET {url} -> {}", resp.status());
    let bytes = resp.bytes().unwrap();
    std::fs::write(dest, &bytes).unwrap();
}

/// Ensure all three models are present under `{base}/models/{key}/`, returning `base`.
fn ensure_models() -> PathBuf {
    let base = std::env::var("INBOX2_AI_MODELS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir().join("inbox2-ai-models"));
    let models = base.join("models");
    for (key, repo) in MODELS {
        let dir = models.join(key);
        std::fs::create_dir_all(&dir).unwrap();
        download_if_absent(
            &dir.join("model.onnx"),
            &format!("https://huggingface.co/{repo}/resolve/main/onnx/model_quantized.onnx"),
        );
        download_if_absent(
            &dir.join("tokenizer.json"),
            &format!("https://huggingface.co/{repo}/resolve/main/tokenizer.json"),
        );
        download_if_absent(
            &dir.join("config.json"),
            &format!("https://huggingface.co/{repo}/resolve/main/config.json"),
        );
    }
    base
}

fn warmed_engine() -> AIInferenceEngine {
    let base = ensure_models();
    let mut engine = AIInferenceEngine::new(&base);
    engine.warmup().expect("warmup should load all ONNX sessions");
    assert!(engine.is_ready());
    engine
}

#[test]
#[ignore = "downloads ~180MB of models; run with --ignored"]
fn sentiment_distinguishes_polarity() {
    let mut engine = warmed_engine();

    let pos = engine
        .run_sentiment("I absolutely love this, it's wonderful and made my day!")
        .unwrap();
    assert_eq!(pos.label, "POSITIVE", "score={}", pos.score);
    assert!(pos.score > 0.8, "expected confident positive, got {}", pos.score);

    let neg = engine
        .run_sentiment("This is terrible. I hate it and I'm furious.")
        .unwrap();
    assert_eq!(neg.label, "NEGATIVE", "score={}", neg.score);
    assert!(neg.score > 0.8, "expected confident negative, got {}", neg.score);
}

#[test]
#[ignore = "downloads ~180MB of models; run with --ignored"]
fn intent_returns_full_distribution_over_candidate_labels() {
    let mut engine = warmed_engine();

    let result = engine
        .run_intent("Can you send me the quarterly report by Friday?")
        .unwrap();

    // Contract: all 6 candidate labels present, probabilities sum to ~1,
    // and the reported label/score is the argmax.
    let expected: std::collections::HashSet<&str> = [
        "question",
        "request",
        "complaint",
        "FYI",
        "scheduling",
        "other",
    ]
    .into_iter()
    .collect();
    let got: std::collections::HashSet<&str> =
        result.scores.keys().map(|s| s.as_str()).collect();
    assert_eq!(got, expected, "scores must cover exactly the candidate labels");

    let sum: f32 = result.scores.values().sum();
    assert!((sum - 1.0).abs() < 1e-3, "scores should sum to 1, got {sum}");

    let argmax = result
        .scores
        .iter()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap();
    assert_eq!(&result.label, argmax.0);
    assert!((result.score - *argmax.1).abs() < 1e-6);
    assert!(expected.contains(result.label.as_str()));

    eprintln!("intent label={} score={:.3} scores={:?}", result.label, result.score, result.scores);
}

#[test]
#[ignore = "downloads ~180MB of models; run with --ignored"]
fn intent_directional_scheduling_vs_question() {
    let mut engine = warmed_engine();

    let sched = engine
        .run_intent("Let's set up a meeting for next Tuesday at 3pm.")
        .unwrap();
    let question = engine
        .run_intent("What time does the office open on weekends?")
        .unwrap();

    // The scheduling text should score "scheduling" higher than the question
    // text does, and vice-versa for "question" — a directional sanity check
    // that the NLI entailment scoring is actually discriminating.
    assert!(
        sched.scores["scheduling"] > question.scores["scheduling"],
        "scheduling text should out-score question text on 'scheduling'"
    );
    assert!(
        question.scores["question"] > sched.scores["question"],
        "question text should out-score scheduling text on 'question'"
    );
}

#[test]
#[ignore = "downloads ~180MB of models; run with --ignored"]
fn embedding_is_normalized_384_and_semantically_sensible() {
    let mut engine = warmed_engine();

    let a = engine.run_embedding("The cat sat on the mat.").unwrap();
    assert_eq!(a.dimensions, 384);
    assert_eq!(a.embedding.len(), 384);
    let norm: f32 = a.embedding.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((norm - 1.0).abs() < 1e-3, "embedding should be L2-normalized, norm={norm}");

    // Cosine similarity (dot product, since both are unit vectors): a near-
    // paraphrase should be closer than an unrelated sentence.
    let b = engine.run_embedding("A cat is sitting on a rug.").unwrap();
    let c = engine
        .run_embedding("Quarterly revenue exceeded forecasts.")
        .unwrap();
    let cos = |x: &[f32], y: &[f32]| -> f32 { x.iter().zip(y).map(|(p, q)| p * q).sum() };
    let sim_ab = cos(&a.embedding, &b.embedding);
    let sim_ac = cos(&a.embedding, &c.embedding);
    assert!(
        sim_ab > sim_ac,
        "paraphrase sim ({sim_ab:.3}) should exceed unrelated sim ({sim_ac:.3})"
    );
}
