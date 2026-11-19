// Progressive Matching — decision logic for AI backend selection.
// Given an AICapabilities report, determines the runtime path for each feature tier.

/**
 * @typedef {Object} AIBackendDecision
 * @property {boolean} classificationEnabled - Whether classification can run
 * @property {'webgpu' | 'wasm' | 'tauri-ort'} classificationBackend
 * @property {boolean} generativeEnabled - Whether generative features can run
 * @property {'apple-foundation-models' | 'tauri-native' | 'webgpu-webllm' | 'none'} generativeBackend
 * @property {string} classificationReason - Human-readable explanation
 * @property {string} generativeReason - Human-readable explanation
 */

/**
 * Determine the backend decision for all AI features given capabilities.
 * Tier A (classification/embeddings) is always enabled — WASM is the universal fallback.
 * Tier B (generative) is scaffolded — returns the intended backend but is not yet implemented.
 *
 * @param {import('./capabilities').AICapabilities} capabilities
 * @returns {AIBackendDecision}
 */
export function matchBackends(capabilities) {
  const {
    classificationBackend,
    generativeBackend,
    isDesktop,
    hasWebGPU,
    deviceMemory,
  } = capabilities;

  // Classification reasoning
  let classificationReason;
  if (classificationBackend === 'tauri-ort') {
    classificationReason = 'Runs natively on this device';
  } else if (classificationBackend === 'webgpu') {
    classificationReason = 'Runs on your graphics chip in the browser';
  } else {
    classificationReason = 'Runs on your processor, which is slower';
  }

  // Generative reasoning
  let generativeReason;
  if (generativeBackend === 'apple-foundation-models') {
    generativeReason = 'Apple Intelligence works on this Mac (macOS 26+)';
  } else if (generativeBackend === 'tauri-native') {
    generativeReason = 'Works on this computer after a one-time download';
  } else if (generativeBackend === 'webgpu-webllm') {
    generativeReason = `${deviceMemory} GB of memory is enough to run AI in the browser`;
  } else {
    if (!isDesktop && !hasWebGPU) {
      generativeReason = "This browser can't run AI writing features";
    } else if (!isDesktop && deviceMemory < 4) {
      generativeReason = "This device doesn't have enough memory for AI writing";
    } else {
      generativeReason = "AI writing isn't available on this device";
    }
  }

  return {
    classificationEnabled: true,
    classificationBackend,
    generativeEnabled: generativeBackend !== 'none',
    generativeBackend,
    classificationReason,
    generativeReason,
  };
}

// ─── Tier B Provider Interface ───────────────────────────────────────────────

/**
 * @typedef {Object} GenerativeInferenceProvider
 * @property {(options?: object) => Promise<void>} initialize - Load/prepare the model
 * @property {(text: string, senderName: string) => Promise<string[]>} generateSmartReplies
 * @property {(text: string) => Promise<string>} summarize
 * @property {(systemPrompt: string, userInput: string, options?: object) => Promise<string>} generate
 * @property {() => Promise<void>} dispose - Release resources
 * @property {() => boolean} isReady - Whether the provider is initialized
 */

// Implementations:
// - Apple Foundation Models: swift-bridge/Sources/ + ai/apple_bridge.rs (Tauri)
// - Native LLM (llama.cpp): ai/native_llm.rs (Tauri)
// - WebLLM: generative/webllmProvider.js (browser WebGPU)
// - Tauri combined: generative/tauriProvider.js (routes to Apple FM or native)

/**
 * Legacy factory — use the generative/ module directly instead.
 * Kept for backward compatibility with existing tests.
 *
 * @param {string} backend - One of the GenerativeBackend values
 * @returns {GenerativeInferenceProvider | null}
 */
export function createGenerativeProvider(backend) {
  switch (backend) {
    case 'apple-foundation-models':
    case 'tauri-native':
    case 'webgpu-webllm':
      // Use the generative/ module's initializeGenerative() instead
      return null;
    case 'none':
    default:
      return null;
  }
}
