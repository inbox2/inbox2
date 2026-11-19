// The desktop NLU generation-lane preference (Settings → On-device AI →
// Generation engine) and the engine push that applies it. Mirrors iOS's
// per-capability lane prefs (BridgeVoicePanel): `native` = Apple Intelligence,
// `free` = the local Qwen model, `openai` = the user's key. The picker is
// explicit-only; `auto` exists solely as the stored default for users who never
// chose (the pre-lane-picker behavior: OpenAI when a key exists, else
// on-device) and is never offered as an option.
import { isTauri } from '../tauri';
import log from '../log';
import { NLU_LANE as LANE_KEY, NLU_FREE_MODEL as FREE_MODEL_KEY } from '../storageKeys';

/** The default free-lane variant (the manifest's first NLU free entry on desktop). */
export const DEFAULT_FREE_MODEL = 'qwen2.5-1.5b-instruct-gguf';

export function getNluLane() {
  return localStorage.getItem(LANE_KEY) || 'auto';
}

export function setNluLane(lane) {
  localStorage.setItem(LANE_KEY, lane);
}

/** The free lane's model variant choice (a manifest GGUF id — Qwen or Gemma). */
export function getNluFreeModel() {
  return localStorage.getItem(FREE_MODEL_KEY) || DEFAULT_FREE_MODEL;
}

export function setNluFreeModel(id) {
  localStorage.setItem(FREE_MODEL_KEY, id);
}

/**
 * Apply the lane choice to the engine: push the triage-worker config
 * (`set_ai_config`) and, for on-device lanes, warm the matching generative
 * backend so background triage can generate without a Settings visit.
 * Never triggers a model download — the free lane only initializes when its
 * model is already installed (booting must not start a silent 1.1 GB fetch).
 */
export async function applyNluLane(lane = getNluLane()) {
  if (!isTauri()) return;
  try {
    const { getSecret } = await import('../secretStore');
    const key = await getSecret('openai_api_key');
    const { invoke } = await import('@tauri-apps/api/core');
    const generation =
      lane === 'openai' ? 'openai'
        : lane === 'native' || lane === 'free' ? 'apple'
          : key ? 'openai' : 'apple';
    // The exact on-device engine, recorded as triage provenance (`triage_source`).
    // `auto` stays null (backend resolved engine-side) → the bare lane tag.
    const onDeviceModel =
      lane === 'native' ? 'apple-fm'
        : lane === 'free' ? getNluFreeModel()
          : null;
    await invoke('set_ai_config', { generation, openaiKey: key || null, model: null, onDeviceModel });
    if (generation === 'openai') return;

    const lanes = await invoke('model_lanes', { capability: 'nlu', hasValidKey: !!key });
    const native = lanes.find(l => l.lane === 'native');
    const free = lanes.find(l => l.lane === 'free');
    // The free lane runs the user's variant choice (Qwen or Gemma) — it only
    // initializes when THAT variant is installed; an installed other variant
    // doesn't silently swap the model.
    const variants = await invoke('free_model_variants', { capability: 'nlu' });
    const freeModel = getNluFreeModel();
    const variantReady = variants.find(v => v.id === freeModel)?.state === 'installed';
    if (lane === 'native' && native?.available) {
      await invoke('initialize_generative', { lane: 'native' });
    } else if (lane === 'free' && variantReady) {
      await invoke('initialize_generative', { lane: 'free', freeModel });
    } else if (lane === 'auto' && (native?.available || free?.state === 'installed')) {
      await invoke('initialize_generative', {});
    }
  } catch (e) {
    log.warn('lanePrefs', `apply lane '${lane}' failed: ${e?.message || e}`);
  }
}
