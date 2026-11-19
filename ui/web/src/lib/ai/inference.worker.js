// AI Inference Web Worker
// Runs sentiment, intent, and embedding inference off the main UI thread.
// Communicates via postMessage with the main thread.

import { pipeline, env } from '@huggingface/transformers';

// Configure Transformers.js for browser worker context
env.useBrowserCache = true;
env.allowLocalModels = false;

const MODEL_CONFIG = {
  sentiment: {
    repo: 'Xenova/distilbert-base-uncased-finetuned-sst-2-english',
    task: 'text-classification',
  },
  intent: {
    repo: 'Xenova/nli-deberta-v3-xsmall',
    task: 'zero-shot-classification',
  },
  embeddings: {
    repo: 'Xenova/all-MiniLM-L6-v2',
    task: 'feature-extraction',
  },
};

const INTENT_LABELS = ['question', 'request', 'complaint', 'FYI', 'scheduling', 'other'];

// Pipeline cache — loaded once, reused across inferences
const pipelines = {};

/**
 * Load a pipeline (or return cached instance).
 */
async function getPipeline(modelKey) {
  if (pipelines[modelKey]) return pipelines[modelKey];

  const config = MODEL_CONFIG[modelKey];
  if (!config) throw new Error(`Unknown model: ${modelKey}`);

  const pipe = await pipeline(config.task, config.repo, {
    quantized: true,
    dtype: 'int8',
  });

  pipelines[modelKey] = pipe;
  return pipe;
}

/**
 * Run sentiment analysis on input text.
 * @returns {{ label: string, score: number }}
 */
async function runSentiment(text) {
  const pipe = await getPipeline('sentiment');
  const results = await pipe(text, { topk: 1 });
  const top = Array.isArray(results[0]) ? results[0][0] : results[0];
  return { label: top.label, score: top.score };
}

/**
 * Run intent classification via zero-shot NLI.
 * @returns {{ label: string, score: number, scores: Object<string, number> }}
 */
async function runIntent(text) {
  const pipe = await getPipeline('intent');
  const result = await pipe(text, INTENT_LABELS, {
    multi_label: false,
  });
  // zero-shot-classification returns { labels: [...], scores: [...] }
  const scores = {};
  for (let i = 0; i < result.labels.length; i++) {
    scores[result.labels[i]] = result.scores[i];
  }
  return {
    label: result.labels[0],
    score: result.scores[0],
    scores,
  };
}

/**
 * Generate text embeddings.
 * @returns {{ embedding: number[], dimensions: number }}
 */
async function runEmbedding(text) {
  const pipe = await getPipeline('embeddings');
  const output = await pipe(text, { pooling: 'mean', normalize: true });
  // output is a Tensor — extract data as plain array
  const embedding = Array.from(output.data);
  return { embedding, dimensions: embedding.length };
}

/**
 * Warm up all pipelines by running a minimal inference.
 */
async function warmup() {
  const warmupText = 'hello';
  await Promise.all([
    runSentiment(warmupText),
    runIntent(warmupText),
    runEmbedding(warmupText),
  ]);
}

// ─── Message Handler ─────────────────────────────────────────────────────────

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;

  try {
    let result;
    switch (type) {
      case 'warmup':
        await warmup();
        result = { ready: true };
        break;
      case 'sentiment':
        result = await runSentiment(payload.text);
        break;
      case 'intent':
        result = await runIntent(payload.text);
        break;
      case 'embedding':
        result = await runEmbedding(payload.text);
        break;
      default:
        throw new Error(`Unknown message type: ${type}`);
    }
    self.postMessage({ id, type: 'result', result });
  } catch (err) {
    self.postMessage({ id, type: 'error', error: err.message });
  }
};
