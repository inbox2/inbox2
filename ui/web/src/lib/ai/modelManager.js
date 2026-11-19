// Model Acquisition & Caching Layer (Web)
// Manages model downloads via Transformers.js with progress tracking,
// IndexedDB caching, and model removal.

import { isTauri } from '../tauri';
import log from '../log';
import { MODEL_REGISTRY, MODEL_HOST_URL } from './models';
import { AI_MODELS as STORAGE_KEY, AI_CONSENT as CONSENT_KEY } from '../storageKeys';

/**
 * @typedef {Object} ModelStatus
 * @property {string} id - Model identifier
 * @property {string} name - Human-readable name
 * @property {'not_downloaded' | 'downloading' | 'ready' | 'error'} status
 * @property {number} progress - Download progress 0-100
 * @property {number} sizeMB - Approximate size
 * @property {string|null} error - Error message if status is 'error'
 * @property {string|null} version - Cached model version/revision
 */

/**
 * Get the stored model metadata from localStorage.
 * @returns {Object<string, {version: string, downloadedAt: string}>}
 */
function getStoredMetadata() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function setStoredMetadata(metadata) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(metadata));
}

/**
 * Check if user has given AI consent.
 * @returns {boolean}
 */
export function hasAIConsent() {
  return localStorage.getItem(CONSENT_KEY) === 'granted';
}

/**
 * Record user's AI consent decision.
 * @param {boolean} granted
 */
export function setAIConsent(granted) {
  if (granted) {
    localStorage.setItem(CONSENT_KEY, 'granted');
  } else {
    localStorage.removeItem(CONSENT_KEY);
  }
}

/**
 * Get status of all Tier A models.
 * @returns {ModelStatus[]}
 */
export function getModelStatuses() {
  const stored = getStoredMetadata();
  return Object.entries(MODEL_REGISTRY).map(([key, model]) => {
    const meta = stored[key];
    return {
      id: model.id,
      name: model.name,
      status: meta ? 'ready' : 'not_downloaded',
      progress: meta ? 100 : 0,
      sizeMB: model.approxSizeMB,
      error: null,
      version: meta?.version || null,
    };
  });
}

/**
 * Check if all Tier A models are downloaded and ready.
 * @returns {boolean}
 */
export function allModelsReady() {
  const stored = getStoredMetadata();
  return Object.keys(MODEL_REGISTRY).every(key => stored[key]);
}

/**
 * Download all Tier A models with progress callback.
 * Uses Transformers.js which handles IndexedDB caching internally.
 *
 * @param {(progress: {model: string, percent: number, overall: number}) => void} onProgress
 * @returns {Promise<{success: boolean, errors: string[]}>}
 */
export async function downloadAllModels(onProgress) {
  if (isTauri()) {
    return downloadModelsDesktop(onProgress);
  }
  return downloadModelsWeb(onProgress);
}

/**
 * Web path: download models via Transformers.js (auto-caches in IndexedDB).
 */
async function downloadModelsWeb(onProgress) {
  const { env, pipeline } = await import('@huggingface/transformers');

  // Configure model host if overridden
  if (MODEL_HOST_URL) {
    env.remoteHost = MODEL_HOST_URL;
  }
  // Use IndexedDB cache (default for browser)
  env.useBrowserCache = true;
  env.allowLocalModels = false;

  const modelKeys = Object.keys(MODEL_REGISTRY);
  const errors = [];
  const stored = getStoredMetadata();

  for (let i = 0; i < modelKeys.length; i++) {
    const key = modelKeys[i];
    const model = MODEL_REGISTRY[key];

    try {
      const progressCallback = (data) => {
        if (data.status === 'progress' && data.progress != null) {
          const modelPercent = Math.round(data.progress);
          const overall = Math.round(((i + modelPercent / 100) / modelKeys.length) * 100);
          onProgress?.({ model: model.name, percent: modelPercent, overall });
        }
      };

      // Creating a pipeline triggers the model download + cache
      const pipe = await pipeline(model.task, model.repo, {
        quantized: true,
        progress_callback: progressCallback,
        dtype: 'int8',
      });

      // Dispose immediately — we just needed to trigger the download/cache
      if (pipe.dispose) await pipe.dispose();

      stored[key] = {
        version: model.quantization,
        downloadedAt: new Date().toISOString(),
      };
      setStoredMetadata(stored);

      onProgress?.({ model: model.name, percent: 100, overall: Math.round(((i + 1) / modelKeys.length) * 100) });
    } catch (err) {
      errors.push(`${model.name}: ${err.message}`);
    }
  }

  return { success: errors.length === 0, errors };
}

/**
 * Desktop (Tauri) path: download models via Rust backend.
 */
async function downloadModelsDesktop(onProgress) {
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    const { listen } = await import('@tauri-apps/api/event');

    const modelKeys = Object.keys(MODEL_REGISTRY);
    const errors = [];
    const stored = getStoredMetadata();

    // Listen for download progress events from Rust
    const unlisten = await listen('ai-model-download-progress', (event) => {
      const { model_name, percent, overall } = event.payload;
      onProgress?.({ model: model_name, percent, overall });
    });

    try {
      const models = modelKeys.map(key => ({
        key,
        repo: MODEL_REGISTRY[key].repo,
        name: MODEL_REGISTRY[key].name,
        task: MODEL_REGISTRY[key].task,
      }));

      const result = await invoke('download_ai_models', { models });

      if (result.errors && result.errors.length > 0) {
        errors.push(...result.errors);
      }

      // Update stored metadata for successful downloads
      for (const key of modelKeys) {
        if (!errors.some(e => e.includes(MODEL_REGISTRY[key].name))) {
          stored[key] = {
            version: MODEL_REGISTRY[key].quantization,
            downloadedAt: new Date().toISOString(),
          };
        }
      }
      setStoredMetadata(stored);
    } finally {
      unlisten();
    }

    return { success: errors.length === 0, errors };
  } catch (err) {
    return { success: false, errors: [err.message] };
  }
}

/**
 * Remove all cached models and free disk/IndexedDB space.
 * @returns {Promise<void>}
 */
export async function removeAllModels() {
  if (isTauri()) {
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('remove_ai_models');
    } catch (err) {
      log.error('AIModels', `Failed to remove desktop models: ${err?.message || err}`);
    }
  } else {
    // Clear Transformers.js IndexedDB cache
    try {
      const databases = await indexedDB.databases();
      for (const db of databases) {
        if (db.name && db.name.includes('transformers')) {
          indexedDB.deleteDatabase(db.name);
        }
      }
    } catch {
      // indexedDB.databases() not supported in all browsers — fallback
      try {
        indexedDB.deleteDatabase('transformers-cache');
      } catch { /* best effort */ }
    }
  }

  // Clear stored metadata
  localStorage.removeItem(STORAGE_KEY);
  setAIConsent(false);
}

/**
 * Get approximate disk usage for all cached models.
 * @returns {Promise<{totalMB: number, models: Array<{name: string, sizeMB: number}>}>}
 */
export async function getModelDiskUsage() {
  if (isTauri()) {
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      return await invoke('get_ai_model_disk_usage');
    } catch {
      return { totalMB: 0, models: [] };
    }
  }

  // Web: estimate from registry for downloaded models
  const stored = getStoredMetadata();
  const models = [];
  let totalMB = 0;
  for (const [key, model] of Object.entries(MODEL_REGISTRY)) {
    if (stored[key]) {
      models.push({ name: model.name, sizeMB: model.approxSizeMB });
      totalMB += model.approxSizeMB;
    }
  }
  return { totalMB, models };
}
