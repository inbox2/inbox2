// Tauri Generative Provider
// Routes generative AI calls to Rust backend commands.
// The Rust side dispatches to either Apple Foundation Models or native LLM.
// Implements the GenerativeInferenceProvider interface.

let ready = false;
let initializing = false;

async function invoke(command, args = {}) {
  const { invoke: tauriInvoke } = await import('@tauri-apps/api/core');
  return tauriInvoke(command, args);
}

/**
 * Tauri-based generative provider for desktop native inference.
 * @implements {GenerativeInferenceProvider}
 */
const tauriProvider = {
  /**
   * Initialize the generative backend (Apple FM or native LLM).
   * @param {Object} [options]
   * @param {(progress: {text: string, progress: number}) => void} [options.onProgress]
   * @returns {Promise<void>}
   */
  async initialize(options = {}) {
    if (ready) return;
    if (initializing) {
      return new Promise((resolve) => {
        const check = setInterval(() => {
          if (ready) { clearInterval(check); resolve(); }
        }, 100);
      });
    }

    initializing = true;

    try {
      // Listen for progress events if callback provided
      let unlisten = null;
      if (options.onProgress) {
        const { listen } = await import('@tauri-apps/api/event');
        unlisten = await listen('generative-model-progress', (event) => {
          options.onProgress(event.payload);
        });
      }

      try {
        await invoke('initialize_generative');
        ready = true;
      } finally {
        if (unlisten) unlisten();
      }
    } catch (err) {
      ready = false;
      throw err;
    } finally {
      initializing = false;
    }
  },

  /**
   * Generate smart reply suggestions.
   * @param {string} text - Email body text
   * @param {string} senderName - Name of the sender
   * @returns {Promise<string[]>}
   */
  async generateSmartReplies(text, senderName) {
    if (!ready) throw new Error('Generative backend not initialized');
    return invoke('generative_smart_replies', { text, senderName });
  },

  /**
   * Summarize an email thread.
   * @param {string} text - Full thread text
   * @returns {Promise<string>}
   */
  async summarize(text) {
    if (!ready) throw new Error('Generative backend not initialized');
    return invoke('generative_summarize', { text });
  },

  /**
   * Free-form generation.
   * @param {string} systemPrompt
   * @param {string} userInput
   * @param {Object} [options]
   * @returns {Promise<string>}
   */
  async generate(systemPrompt, userInput, options) {
    if (!ready) throw new Error('Generative backend not initialized');
    return invoke('generative_generate', {
      system: systemPrompt,
      prompt: userInput,
      maxTokens: options?.maxTokens ?? 300,
      temperature: options?.temperature ?? 0.5,
    });
  },

  /**
   * Release resources and stop the backend.
   */
  async dispose() {
    if (ready) {
      try {
        await invoke('stop_generative');
      } catch { /* may already be stopped */ }
    }
    ready = false;
    initializing = false;
  },

  /**
   * Check if the provider is ready.
   */
  isReady() {
    return ready;
  },
};

export default tauriProvider;
