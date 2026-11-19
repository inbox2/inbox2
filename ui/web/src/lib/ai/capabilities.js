// AI Capability Detection Module
// Probes device hardware and runtime to determine which AI features can run.

import { isTauri } from '../tauri';

/**
 * @typedef {'webgpu' | 'wasm' | 'tauri-ort'} ClassificationBackend
 * @typedef {'apple-foundation-models' | 'tauri-native' | 'webgpu-webllm' | 'none'} GenerativeBackend
 *
 * @typedef {Object} AICapabilities
 * @property {boolean} canRunClassification - Whether Tier A (sentiment/intent/embeddings) can run
 * @property {boolean} canRunGenerative - Whether Tier B (generative) could potentially run
 * @property {ClassificationBackend} classificationBackend - Selected backend for classification
 * @property {GenerativeBackend} generativeBackend - Selected backend for generative (scaffolded)
 * @property {boolean} hasWebGPU - Whether WebGPU is available
 * @property {number} deviceMemory - Approximate device memory in GB (0 if unknown)
 * @property {number} hardwareConcurrency - Number of logical CPU cores
 * @property {boolean} isDesktop - Whether running inside Tauri
 * @property {boolean} hasAppleFoundationModels - Whether Apple on-device models are available (macOS 26+)
 */

const GENERATIVE_MIN_MEMORY_GB = 4;

/**
 * Detect WebGPU availability by requesting an adapter.
 * @returns {Promise<boolean>}
 */
async function detectWebGPU() {
  if (typeof navigator === 'undefined' || !navigator.gpu) {
    return false;
  }
  try {
    const adapter = await navigator.gpu.requestAdapter();
    return adapter !== null;
  } catch {
    return false;
  }
}

/**
 * Get approximate device memory in GB.
 * Falls back to 0 if the API is unavailable.
 * @returns {number}
 */
function getDeviceMemory() {
  if (typeof navigator !== 'undefined' && navigator.deviceMemory) {
    return navigator.deviceMemory;
  }
  return 0;
}

/**
 * Get hardware concurrency (logical cores).
 * @returns {number}
 */
function getHardwareConcurrency() {
  if (typeof navigator !== 'undefined' && navigator.hardwareConcurrency) {
    return navigator.hardwareConcurrency;
  }
  return 1;
}

/**
 * Check if Apple Foundation Models are available (Tauri + macOS 26+ + Apple Silicon).
 * Calls a Tauri command that probes the native API.
 * @returns {Promise<boolean>}
 */
async function detectAppleFoundationModels() {
  if (!isTauri()) return false;
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    const available = await invoke('check_apple_foundation_models');
    return available === true;
  } catch {
    return false;
  }
}

/**
 * Run full capability detection and return the AICapabilities report.
 * @returns {Promise<AICapabilities>}
 */
export async function detectCapabilities() {
  const isDesktop = isTauri();
  const deviceMemory = getDeviceMemory();
  const hardwareConcurrency = getHardwareConcurrency();

  const [hasWebGPU, hasAppleFoundationModels] = await Promise.all([
    detectWebGPU(),
    detectAppleFoundationModels(),
  ]);

  // Classification backend selection
  let classificationBackend;
  if (isDesktop) {
    classificationBackend = 'tauri-ort';
  } else if (hasWebGPU) {
    classificationBackend = 'webgpu';
  } else {
    classificationBackend = 'wasm';
  }

  // Generative backend selection (Tier B — scaffolded only)
  let generativeBackend;
  if (isDesktop && hasAppleFoundationModels) {
    generativeBackend = 'apple-foundation-models';
  } else if (isDesktop) {
    generativeBackend = 'tauri-native';
  } else if (hasWebGPU && deviceMemory >= GENERATIVE_MIN_MEMORY_GB) {
    generativeBackend = 'webgpu-webllm';
  } else {
    generativeBackend = 'none';
  }

  const canRunClassification = true; // WASM fallback means essentially all devices
  const canRunGenerative = generativeBackend !== 'none';

  return {
    canRunClassification,
    canRunGenerative,
    classificationBackend,
    generativeBackend,
    hasWebGPU,
    deviceMemory,
    hardwareConcurrency,
    isDesktop,
    hasAppleFoundationModels,
  };
}

/**
 * Exported for testing — allows injection of mocked primitives.
 * @param {Object} env - Mocked environment values
 * @returns {AICapabilities}
 */
export function detectCapabilitiesFromEnv({
  hasWebGPU = false,
  deviceMemory = 0,
  hardwareConcurrency = 1,
  isDesktop = false,
  hasAppleFoundationModels = false,
}) {
  let classificationBackend;
  if (isDesktop) {
    classificationBackend = 'tauri-ort';
  } else if (hasWebGPU) {
    classificationBackend = 'webgpu';
  } else {
    classificationBackend = 'wasm';
  }

  let generativeBackend;
  if (isDesktop && hasAppleFoundationModels) {
    generativeBackend = 'apple-foundation-models';
  } else if (isDesktop) {
    generativeBackend = 'tauri-native';
  } else if (hasWebGPU && deviceMemory >= GENERATIVE_MIN_MEMORY_GB) {
    generativeBackend = 'webgpu-webllm';
  } else {
    generativeBackend = 'none';
  }

  const canRunClassification = true;
  const canRunGenerative = generativeBackend !== 'none';

  return {
    canRunClassification,
    canRunGenerative,
    classificationBackend,
    generativeBackend,
    hasWebGPU,
    deviceMemory,
    hardwareConcurrency,
    isDesktop,
    hasAppleFoundationModels,
  };
}
