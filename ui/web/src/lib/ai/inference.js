// AI Inference API — high-level async interface for UI consumption.
// In Tauri: uses Apple Intelligence via the generative provider.
// In browser: uses Web Worker with Transformers.js.

import { isTauri } from '../tauri';
import log from '../log';
import { hasAIConsent, allModelsReady } from './modelManager';
import { isGenerativeReady, generate } from './generative';

let worker = null;
let requestId = 0;
const pendingRequests = new Map();
let isReady = false;
let isInitializing = false;

// Native ONNX Runtime (Tier A) engine — used on desktop when Apple Intelligence
// (the generative provider) isn't available, and as the only on-device path for
// embeddings (the generative LLM can't produce them).
let ortReady = false;
let ortWarmPromise = null;

/**
 * Warm up the native ONNX engine in the Rust backend (idempotent). Resolves
 * false if models aren't downloaded yet or warmup fails — callers then degrade
 * gracefully. The failed promise is cleared so a later attempt (e.g. after the
 * user downloads models) can retry.
 */
async function ensureOrtWarm() {
  if (ortReady) return true;
  if (!isTauri()) return false;
  if (!ortWarmPromise) {
    ortWarmPromise = (async () => {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        await invoke('warmup_ai_models');
        ortReady = true;
        log.info('AI', 'Native ONNX (Tier A) engine warmed');
        return true;
      } catch (e) {
        log.warn('AI', `Native ONNX engine unavailable: ${e?.message || e}`);
        ortWarmPromise = null;
        return false;
      }
    })();
  }
  return ortWarmPromise;
}

/**
 * Run a Tier A task through the native ONNX engine. Returns null on failure so
 * the caller can fall back. Result shapes match the worker / Apple paths.
 */
async function inferViaOrt(type, payload) {
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    const text = payload.text;
    if (type === 'sentiment') return await invoke('ai_sentiment', { text });
    if (type === 'intent') return await invoke('ai_intent', { text });
    if (type === 'embedding') return await invoke('ai_embedding', { text });
    return null;
  } catch (e) {
    log.warn('AI', `Native ONNX inference failed: ${e?.message || e}`);
    return null;
  }
}

/**
 * Initialize the inference engine.
 * In Tauri: piggybacks on the generative engine (Apple Intelligence).
 * In browser: spawns a Web Worker with Transformers.js.
 * @returns {Promise<boolean>} Whether initialization succeeded
 */
export async function initializeInference() {
  if (isReady) return true;
  if (isInitializing) return false;

  // In Tauri: Apple Intelligence (the generative provider) handles
  // sentiment/intent when available; otherwise fall back to the native ONNX
  // engine. Embeddings always use the native engine (see infer()).
  if (isTauri()) {
    // Wait briefly for generative to come up (initialized in parallel on startup).
    for (let i = 0; i < 20; i++) {
      if (isGenerativeReady()) {
        isReady = true;
        return true;
      }
      await new Promise(r => setTimeout(r, 500));
    }
    // No Apple Intelligence / generative — use the native ONNX engine if its
    // models are downloaded.
    if (await ensureOrtWarm()) {
      isReady = true;
      return true;
    }
    // Neither path available — inference stays unavailable.
    return false;
  }

  // Browser path: need consent + models
  if (!hasAIConsent() || !allModelsReady()) return false;

  isInitializing = true;

  try {
    worker = new Worker(
      new URL('./inference.worker.js', import.meta.url),
      { type: 'module' }
    );

    worker.onmessage = (event) => {
      const { id, type, result, error } = event.data;
      const pending = pendingRequests.get(id);
      if (!pending) return;
      pendingRequests.delete(id);

      if (type === 'error') {
        pending.reject(new Error(error));
      } else {
        pending.resolve(result);
      }
    };

    worker.onerror = (err) => {
      log.error('AIWorker', `Worker error: ${err.message}`);
    };

    // Run warmup
    await sendToWorker('warmup', {});
    isReady = true;
    return true;
  } catch (err) {
    log.error('AI', `Initialization failed: ${err?.message || err}`);
    isReady = false;
    return false;
  } finally {
    isInitializing = false;
  }
}

function sendToWorker(type, payload) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    pendingRequests.set(id, { resolve, reject });
    worker.postMessage({ id, type, payload });
  });
}

/**
 * Route inference — Apple Intelligence in Tauri, Web Worker in browser.
 */
async function infer(type, payload) {
  if (!isReady) {
    const initialized = await initializeInference();
    if (!initialized) return null;
  }

  if (isTauri()) {
    // Apple Intelligence handles sentiment/intent when available (it can't
    // embed). Keep it first per the chosen layering.
    if (type !== 'embedding' && isGenerativeReady()) {
      const result = await inferViaAppleIntelligence(type, payload);
      if (result) return result;
    }
    // Native ONNX: the no-generative fallback, and the only on-device path for
    // embeddings. Desktop does not spin up the webview worker.
    if (await ensureOrtWarm()) {
      return inferViaOrt(type, payload);
    }
    return null;
  }

  return sendToWorker(type, payload);
}

/**
 * Use Apple Intelligence for classification via the generative provider.
 */
async function inferViaAppleIntelligence(type, payload) {
  const text = payload.text;

  if (type === 'sentiment') {
    const result = await generate(
      'Classify the sentiment of this text as exactly POSITIVE or NEGATIVE. Respond with ONLY a JSON object: {"label":"POSITIVE" or "NEGATIVE","score":0.0 to 1.0}',
      text,
      { temperature: 0.1, maxTokens: 50 }
    );
    if (!result) return null;
    try {
      const match = result.match(/\{[^}]+\}/);
      return match ? JSON.parse(match[0]) : null;
    } catch {
      return null;
    }
  }

  if (type === 'intent') {
    const result = await generate(
      'Classify the intent of this email as exactly one of: question, request, complaint, FYI, scheduling, other. Respond with ONLY a JSON object: {"label":"<intent>","score":0.0 to 1.0}',
      text,
      { temperature: 0.1, maxTokens: 50 }
    );
    if (!result) return null;
    try {
      const match = result.match(/\{[^}]+\}/);
      return match ? JSON.parse(match[0]) : null;
    } catch {
      return null;
    }
  }

  // Embeddings not available via Apple Intelligence
  return null;
}

/**
 * Analyze sentiment of text.
 * @param {string} text
 * @returns {Promise<{label: string, score: number} | null>}
 */
export async function analyzeSentiment(text) {
  if (!text || text.trim().length === 0) return null;
  const truncated = text.length > 512 ? text.slice(0, 512) : text;
  return infer('sentiment', { text: truncated });
}

/**
 * Classify intent of text.
 * @param {string} text
 * @returns {Promise<{label: string, score: number, scores: Object} | null>}
 */
export async function classifyIntent(text) {
  if (!text || text.trim().length === 0) return null;
  const truncated = text.length > 512 ? text.slice(0, 512) : text;
  return infer('intent', { text: truncated });
}

/**
 * Generate embedding vector for text.
 * @param {string} text
 * @returns {Promise<{embedding: number[], dimensions: number} | null>}
 */
export async function generateEmbedding(text) {
  if (!text || text.trim().length === 0) return null;
  // Embeddings run via the native ONNX engine on desktop, or the Web Worker in
  // the browser. (Apple Intelligence cannot produce embeddings.)
  const truncated = text.length > 512 ? text.slice(0, 512) : text;
  return infer('embedding', { text: truncated });
}

/**
 * Check if inference is ready to accept requests.
 * @returns {boolean}
 */
export function isInferenceReady() {
  return isReady;
}

/**
 * Terminate the inference engine and release resources.
 */
export function disposeInference() {
  if (worker) {
    worker.terminate();
    worker = null;
  }
  pendingRequests.clear();
  isReady = false;
  isInitializing = false;
}
