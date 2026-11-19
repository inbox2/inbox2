// Generative AI Module (Tier B)
// Routes to the correct provider based on progressive matching.
// Providers: WebLLM (browser), Tauri (Apple FM or native LLM)

import { isTauri } from '../../tauri';
import log from '../../log';
import { detectCapabilities } from '../capabilities';
import { matchBackends } from '../matching';
import webllmProvider from './webllmProvider';
import tauriProvider from './tauriProvider';

const MIN_SUMMARIZE_LENGTH = 80;

let activeProvider = null;
let generativeEnabled = null; // null = not yet checked

/**
 * Get the active generative provider based on capabilities.
 * Lazy-initializes on first call.
 * @returns {Promise<{provider: object, backend: string} | null>}
 */
async function resolveProvider() {
  if (generativeEnabled === false) return null;

  if (activeProvider) return activeProvider;

  const caps = await detectCapabilities();
  const decision = matchBackends(caps);

  if (!decision.generativeEnabled) {
    generativeEnabled = false;
    return null;
  }

  generativeEnabled = true;

  if (isTauri()) {
    activeProvider = { provider: tauriProvider, backend: decision.generativeBackend };
  } else if (decision.generativeBackend === 'webgpu-webllm') {
    activeProvider = { provider: webllmProvider, backend: 'webgpu-webllm' };
  } else {
    generativeEnabled = false;
    return null;
  }

  return activeProvider;
}

/**
 * Initialize the generative AI backend.
 * Must be called before using smart replies or summarization.
 * @param {Object} [options]
 * @param {(progress: {text: string, progress: number}) => void} [options.onProgress]
 * @returns {Promise<boolean>} Whether initialization succeeded
 */
export async function initializeGenerative(options = {}) {
  const resolved = await resolveProvider();
  if (!resolved) return false;

  try {
    await resolved.provider.initialize(options);
    return true;
  } catch (err) {
    log.error('Generative', `Init failed: ${err?.message || err}`);
    return false;
  }
}

/**
 * Check if generative AI is available on this device.
 * @returns {Promise<boolean>}
 */
export async function isGenerativeAvailable() {
  const resolved = await resolveProvider();
  return resolved !== null;
}

/**
 * Check if generative AI is initialized and ready.
 * @returns {boolean}
 */
export function isGenerativeReady() {
  return activeProvider?.provider?.isReady() ?? false;
}

/**
 * Generate smart reply suggestions for an email.
 * @param {string} emailText - The email body to reply to
 * @param {string} senderName - Who sent the email
 * @returns {Promise<string[]>} Array of 2-3 suggested replies
 */
export async function generateSmartReplies(emailText, senderName) {
  if (!activeProvider?.provider?.isReady()) return [];
  try {
    const replies = await activeProvider.provider.generateSmartReplies(emailText, senderName);
    return Array.isArray(replies) ? replies : [];
  } catch (err) {
    log.warn('Generative', `Smart replies failed: ${err?.message || err}`);
    return [];
  }
}

/**
 * Human-readable reason the generative backend can't produce output, or null
 * if it's ready. Lets callers log/surface *why* an AI summary is unavailable.
 * @returns {string|null}
 */
export function generativeUnavailableReason() {
  if (activeProvider?.provider?.isReady()) return null;
  if (generativeEnabled === false) {
    return 'no compatible generative backend on this device (WebGPU/Apple Intelligence unavailable)';
  }
  if (!activeProvider) return 'generative backend not initialized';
  return 'generative backend not ready';
}

/**
 * Summarize an email thread.
 * @param {string} threadText - Combined text of the email thread
 * @returns {Promise<{ summary: string|null, reason: string|null }>}
 *   `summary` is the generated text, or null with `reason` set on failure.
 */
export async function summarizeThread(threadText) {
  const unavailable = generativeUnavailableReason();
  if (unavailable) return { summary: null, reason: unavailable };
  // Strip header lines to measure actual body content
  const bodyOnly = threadText.replace(/^From:.*$/gm, '').replace(/^-{3,}$/gm, '').trim();
  if (bodyOnly.length < MIN_SUMMARIZE_LENGTH) {
    return {
      summary: null,
      reason: `thread too short to summarize (${bodyOnly.length} < ${MIN_SUMMARIZE_LENGTH} chars)`,
    };
  }
  try {
    const summary = await activeProvider.provider.summarize(threadText);
    if (!summary || !summary.trim()) {
      return { summary: null, reason: 'model returned an empty summary' };
    }
    return { summary, reason: null };
  } catch (err) {
    const reason = `model error: ${err?.message || err}`;
    log.warn('Generative', `Summarization failed: ${reason}`);
    return { summary: null, reason };
  }
}

/**
 * Free-form generation with custom prompts.
 * @param {string} systemPrompt
 * @param {string} userInput
 * @param {Object} [options]
 * @returns {Promise<string|null>}
 */
export async function generate(systemPrompt, userInput, options) {
  if (!activeProvider?.provider?.isReady()) return null;
  try {
    return await activeProvider.provider.generate(systemPrompt, userInput, options);
  } catch (err) {
    log.warn('Generative', `Generation failed: ${err?.message || err}`);
    return null;
  }
}

/**
 * Get the active generative backend name.
 * @returns {string}
 */
export function getGenerativeBackend() {
  return activeProvider?.backend ?? 'none';
}

/**
 * Dispose generative resources.
 */
export async function disposeGenerative() {
  if (activeProvider?.provider) {
    await activeProvider.provider.dispose();
  }
  activeProvider = null;
  generativeEnabled = null;
}
