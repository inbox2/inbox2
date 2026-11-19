// WebLLM Generative Provider
// Manages the WebLLM Web Worker for browser-based generative AI via WebGPU.
// Implements the GenerativeInferenceProvider interface.

import log from '../../log';

let worker = null;
let requestId = 0;
const pendingRequests = new Map();
let ready = false;
let initializing = false;
let progressCallback = null;

function sendToWorker(type, payload) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    pendingRequests.set(id, { resolve, reject });
    worker.postMessage({ id, type, payload });
  });
}

function handleWorkerMessage(event) {
  const { id, type, result, error, payload } = event.data;

  if (type === 'progress' && progressCallback) {
    progressCallback(payload || event.data.payload);
    return;
  }

  const pending = pendingRequests.get(id);
  if (!pending) return;
  pendingRequests.delete(id);

  if (type === 'error') {
    pending.reject(new Error(error));
  } else {
    pending.resolve(result);
  }
}

/**
 * WebLLM-based generative provider for browser WebGPU inference.
 * @implements {GenerativeInferenceProvider}
 */
const webllmProvider = {
  /**
   * Initialize the WebLLM engine. Downloads model if not cached.
   * @param {Object} [options]
   * @param {string} [options.modelId] - Override default model
   * @param {(progress: {text: string, progress: number}) => void} [options.onProgress]
   * @returns {Promise<void>}
   */
  async initialize(options = {}) {
    if (ready) return;
    if (initializing) {
      // Wait for existing initialization
      return new Promise((resolve) => {
        const check = setInterval(() => {
          if (ready) { clearInterval(check); resolve(); }
        }, 100);
      });
    }

    initializing = true;
    progressCallback = options.onProgress || null;

    try {
      worker = new Worker(
        new URL('./webllm.worker.js', import.meta.url),
        { type: 'module' }
      );

      worker.onmessage = handleWorkerMessage;
      worker.onerror = (err) => {
        log.error('WebLLM', `Worker error: ${err.message}`);
      };

      await sendToWorker('initialize', { modelId: options.modelId });
      ready = true;
    } catch (err) {
      ready = false;
      throw err;
    } finally {
      initializing = false;
      progressCallback = null;
    }
  },

  /**
   * Generate smart reply suggestions for an email.
   * @param {string} text - Email body text
   * @param {string} senderName - Name of the sender
   * @returns {Promise<string[]>} Array of 3 reply suggestions
   */
  async generateSmartReplies(text, senderName) {
    if (!ready) throw new Error('WebLLM not initialized');
    return sendToWorker('smart-replies', { text, senderName });
  },

  /**
   * Summarize an email thread.
   * @param {string} text - Full thread text
   * @returns {Promise<string>} Summary text
   */
  async summarize(text) {
    if (!ready) throw new Error('WebLLM not initialized');
    return sendToWorker('summarize', { text });
  },

  /**
   * Free-form generation.
   * @param {string} systemPrompt
   * @param {string} userInput
   * @param {Object} [options]
   * @returns {Promise<string>}
   */
  async generate(systemPrompt, userInput, options) {
    if (!ready) throw new Error('WebLLM not initialized');
    return sendToWorker('generate', { systemPrompt, userInput, options });
  },

  /**
   * Release resources and terminate worker.
   */
  async dispose() {
    if (worker) {
      try {
        await sendToWorker('dispose', {});
      } catch { /* worker may already be gone */ }
      worker.terminate();
      worker = null;
    }
    pendingRequests.clear();
    ready = false;
    initializing = false;
  },

  /**
   * Check if the provider is ready for inference.
   */
  isReady() {
    return ready;
  },
};

export default webllmProvider;
