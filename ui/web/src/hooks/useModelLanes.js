import { useState, useEffect, useCallback } from 'react';
import { isTauri } from '../lib/tauri';
import { disposeGenerative } from '../lib/ai';
import {
  getNluLane,
  setNluLane,
  applyNluLane,
  getNluFreeModel,
  setNluFreeModel,
} from '../lib/ai/lanePrefs';

/** Human size for a manifest byte count. */
function gb(bytes) {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

/** Display name for a free-lane variant's manifest id. */
function variantName(id) {
  if (id?.startsWith('gemma3-1b')) return 'Gemma 3 1B';
  if (id?.startsWith('qwen2.5-1.5b')) return 'Qwen 2.5 1.5B';
  return id || 'Local model';
}

/** The variant's trade-off, shown under its name. */
function variantTrait(id) {
  return id?.startsWith('gemma3-1b')
    ? 'Smaller and faster, English only'
    : 'Best quality, many languages';
}

/**
 * The generation-engine lane state machine: model lanes from the core manifest,
 * free-model variants + their download/disk state, the persisted lane choice,
 * and the OpenAI-key flow. Returns render-ready rows + the handlers the picker
 * wires to. `ready` is false until lanes load (or off-desktop), so the caller
 * renders nothing — preserving the original mount-gated effects.
 */
export default function useModelLanes() {
  const [lanes, setLanes] = useState(null);
  const [variants, setVariants] = useState([]);
  const [pref, setPref] = useState(getNluLane());
  const [freeModel, setFreeModel] = useState(getNluFreeModel());
  const [hasKey, setHasKey] = useState(false);
  const [keyDraft, setKeyDraft] = useState('');
  const [keyStatus, setKeyStatus] = useState('');
  const [download, setDownload] = useState(null); // live model-download payload
  const [error, setError] = useState(null);

  const refresh = useCallback(async () => {
    try {
      const { getSecret } = await import('../lib/secretStore');
      const key = await getSecret('openai_api_key');
      setHasKey(!!key);
      const { invoke } = await import('@tauri-apps/api/core');
      const ls = await invoke('model_lanes', { capability: 'nlu', hasValidKey: !!key });
      setLanes(ls);
      setVariants(await invoke('free_model_variants', { capability: 'nlu' }));
      // The picker is explicit-only. A user who never chose still runs the
      // legacy default (OpenAI when a key exists, else on-device) — show THAT
      // as the selection until they click; the first click persists a choice.
      if (getNluLane() === 'auto') {
        const nativeOk = ls.find(l => l.lane === 'native')?.available;
        setPref(key ? 'openai' : nativeOk ? 'native' : 'free');
      }
    } catch (e) {
      setError(String(e?.message || e));
    }
  }, []);

  // eslint-disable-next-line react-hooks/set-state-in-effect -- intentional: async lane load on mount
  useEffect(() => { refresh(); }, [refresh]);

  // Live download progress from the core download manager.
  useEffect(() => {
    let unlisten = null;
    let active = true;
    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      const fn = await listen('model-download', (e) => {
        const p = e.payload || {};
        if (p.capability !== 'nlu') return;
        setDownload(p.state === 'installed' || p.state === 'failed' ? null : p);
        if (p.state === 'failed' && p.error) setError(p.error);
        if (p.state === 'installed') {
          refresh();
          // The user picked the local model and its download just landed —
          // activate it now.
          if (getNluLane() === 'free') applyNluLane('free');
        }
      });
      if (active) unlisten = fn; else fn();
    })();
    return () => { active = false; unlisten?.(); };
  }, [refresh]);

  const choose = async (lane) => {
    setError(null);
    setPref(lane);
    setNluLane(lane);
    if (lane === 'openai' && !hasKey) {
      // Selecting OpenAI reveals the key field; the lane activates on save.
      return;
    }
    const variant = variants.find(v => v.id === getNluFreeModel());
    if (lane === 'free' && variant?.state === 'absent') {
      try {
        const { invoke } = await import('@tauri-apps/api/core');
        await invoke('model_download', { id: variant.id });
      } catch (e) {
        setError(String(e?.message || e));
      }
      return; // activation happens when the download completes
    }
    await applyNluLane(lane);
    refresh();
  };

  // Pick the free lane's model variant (Qwen ⇄ Gemma). Selecting a variant also
  // selects the free lane; an absent variant downloads first and activates when
  // the download lands (the model-download listener applies it).
  const chooseVariant = async (v) => {
    setError(null);
    setFreeModel(v.id);
    setNluFreeModel(v.id);
    setPref('free');
    setNluLane('free');
    if (v.state !== 'installed') {
      if (v.state === 'absent') {
        try {
          const { invoke } = await import('@tauri-apps/api/core');
          await invoke('model_download', { id: v.id });
        } catch (e) {
          setError(String(e?.message || e));
        }
      }
      return;
    }
    await applyNluLane('free');
    refresh();
  };

  const deleteVariant = async (id) => {
    setError(null);
    try {
      disposeGenerative();
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('model_delete', { id });
      if ((getNluLane() === 'free' || pref === 'free') && id === getNluFreeModel()) {
        // The running variant just got deleted — switch to the other installed
        // variant if there is one, else fall back off the free lane explicitly.
        const other = variants.find(v => v.id !== id && v.state === 'installed');
        if (other) {
          setFreeModel(other.id);
          setNluFreeModel(other.id);
          await applyNluLane('free');
        } else {
          const next = lanes?.find(l => l.lane === 'native')?.available
            ? 'native'
            : hasKey ? 'openai' : 'native';
          setNluLane(next);
          setPref(next);
          await applyNluLane(next);
        }
      }
      refresh();
    } catch (e) {
      setError(String(e?.message || e));
    }
  };

  const saveKey = async () => {
    const key = keyDraft.trim();
    if (!key) return;
    setKeyStatus('Validating…');
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('bridge_validate_openai', { key });
      const { setSecret } = await import('../lib/secretStore');
      await setSecret('openai_api_key', key);
      setKeyDraft('');
      setKeyStatus('Validated ✓');
      await applyNluLane(pref);
      refresh();
    } catch (e) {
      setKeyStatus(String(e?.message || e));
    }
  };

  const native = lanes?.find(l => l.lane === 'native');
  const free = lanes?.find(l => l.lane === 'free');
  const pct = download && download.total_bytes > 0
    ? Math.round((download.received_bytes / download.total_bytes) * 100)
    : null;
  const selectedVariant = variants.find(v => v.id === freeModel);

  const rows = [
    native && {
      lane: 'native',
      name: 'Apple Intelligence',
      desc: native.available ? 'Runs on this Mac. Nothing to download.' : (native.reason || 'Not available.'),
      enabled: native.available,
    },
    free && {
      lane: 'free',
      name: `Local model: ${variantName(freeModel)}`,
      desc: download
        ? `Downloading ${variantName(download.id)}… ${pct ?? 0}%`
        : selectedVariant?.state === 'installed'
          ? `Runs on this device. Installed (${gb(selectedVariant.totalBytes)}).`
          : `Runs on this device. One-time ${gb(selectedVariant?.totalBytes ?? free.totalBytes)} download.`,
      enabled: free.available,
    },
    {
      lane: 'openai',
      name: 'OpenAI',
      desc: hasKey
        ? 'Uses your API key. Your mail leaves this device.'
        : 'Add an API key to use this.',
      enabled: true,
    },
  ].filter(Boolean);

  const variantRows = variants.map(v => ({
    ...v,
    name: variantName(v.id),
    desc: download?.id === v.id
      ? `Downloading… ${pct ?? 0}%`
      : v.state === 'installed'
        ? `${variantTrait(v.id)} · ${gb(v.totalBytes)} on disk.`
        : `${variantTrait(v.id)} · one-time ${gb(v.totalBytes)} download.`,
  }));

  return {
    ready: isTauri() && !!lanes,
    pref, freeModel, download, pct, hasKey,
    keyDraft, setKeyDraft, keyStatus, setKeyStatus, error,
    rows, variantRows,
    choose, chooseVariant, deleteVariant, saveKey,
  };
}
