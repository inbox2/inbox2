// Model configuration for on-device AI inference.
// Model identity is configuration — these can be swapped without code changes.

/**
 * Model registry. Each entry defines a model used for a specific task.
 * Quantization and size are approximate; actual download may vary slightly.
 */
export const MODEL_REGISTRY = {
  sentiment: {
    id: 'distilbert-sst2-int8',
    name: 'Sentiment classifier',
    // DistilBERT fine-tuned on SST-2, quantized to INT8 ONNX
    repo: 'Xenova/distilbert-base-uncased-finetuned-sst-2-english',
    task: 'text-classification',
    quantization: 'int8',
    approxSizeMB: 67,
    labels: ['NEGATIVE', 'POSITIVE'],
  },
  intent: {
    id: 'minilm-intent-int8',
    name: 'Intent classifier',
    // MiniLM fine-tuned for zero-shot classification over intent labels
    repo: 'Xenova/nli-deberta-v3-xsmall',
    task: 'zero-shot-classification',
    quantization: 'int8',
    approxSizeMB: 90,
    labels: ['question', 'request', 'complaint', 'FYI', 'scheduling', 'other'],
  },
  embeddings: {
    id: 'minilm-l6-v2-int8',
    name: 'Text embeddings',
    // all-MiniLM-L6-v2 for sentence embeddings, INT8 ONNX
    repo: 'Xenova/all-MiniLM-L6-v2',
    task: 'feature-extraction',
    quantization: 'int8',
    approxSizeMB: 23,
    dimensions: 384,
  },
};

/**
 * Returns total approximate download size for all Tier A models in MB.
 */
export function getTierADownloadSizeMB() {
  return Object.values(MODEL_REGISTRY).reduce((sum, m) => sum + m.approxSizeMB, 0);
}

/**
 * Model host URL — configurable base for model file downloads.
 * Transformers.js handles the actual download from Hugging Face Hub by default.
 * Override this for self-hosted model mirrors.
 */
export const MODEL_HOST_URL = typeof import.meta !== 'undefined' && import.meta.env?.VITE_MODEL_HOST_URL
  ? import.meta.env.VITE_MODEL_HOST_URL
  : null; // null = use default Hugging Face Hub CDN
