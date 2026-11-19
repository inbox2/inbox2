import { useState, useEffect, useCallback } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { slugifyTriageLabel } from '../lib/triage';

/** Source key for the local-channel label list (engine setting, over Tauri). */
export const LOCAL_TRIAGE_LABELS = 'local';

/*
 * Jev triage labels (docs/Triage.md), from one of two sources:
 *   - LOCAL_TRIAGE_LABELS: the engine's list for local channels
 *     (get/set_triage_labels — the whole list is replaced on every write);
 *   - an org id: the MX org's list over the API (per-label CRUD, admin writes).
 *
 * Lists are cached per source for the session (rows only need a custom label's
 * name) and every mounted hook sees an edit as soon as it's saved.
 */
const cache = new Map(); // source → Promise<label[]>
const listeners = new Set();

async function fetchLabels(source) {
  if (source === LOCAL_TRIAGE_LABELS) {
    const { invoke } = await import('@tauri-apps/api/core');
    return (await invoke('get_triage_labels')) || [];
  }
  return (await api.getTriageLabels(source)).triage_labels || [];
}

function load(source) {
  if (!cache.has(source)) {
    cache.set(source, fetchLabels(source).catch((e) => {
      log.warn('useTriageLabels', `load ${source} failed: ${e?.message || e}`);
      cache.delete(source); // retry on the next mount
      return [];
    }));
  }
  return cache.get(source);
}

/** One source's label list as a promise (cached) — for loaders outside a component. */
export const loadTriageLabels = load;

function publish(source, labels) {
  cache.set(source, Promise.resolve(labels));
  listeners.forEach((fn) => fn(source, labels));
}

// Tauri rejects with the command's error string; the API with an Error.
const message = (e) => String(e?.message || e);

/**
 * `source` = LOCAL_TRIAGE_LABELS | an org id | null (nothing to load).
 * Returns `{ labels, create, update, remove }`; `labels` is null until loaded.
 * The mutations throw a user-displayable Error on a rejected write.
 */
export default function useTriageLabels(source) {
  const [state, setState] = useState({ source: null, labels: null });

  useEffect(() => {
    if (!source) return undefined;
    let live = true;
    load(source).then((labels) => { if (live) setState({ source, labels }); });
    const onPublish = (s, labels) => { if (s === source) setState({ source, labels }); };
    listeners.add(onPublish);
    return () => { live = false; listeners.delete(onPublish); };
  }, [source]);

  const labels = state.source === source ? state.labels : null;

  // Local: validate + store the whole list; the engine returns it as stored.
  const saveLocal = useCallback(async (next) => {
    const { invoke } = await import('@tauri-apps/api/core');
    try {
      publish(LOCAL_TRIAGE_LABELS, await invoke('set_triage_labels', { labels: next }));
    } catch (e) {
      throw new Error(message(e), { cause: e });
    }
  }, []);

  // API: one write, then re-read so positions/defaults come from the server.
  const writeApi = useCallback(async (write) => {
    try {
      await write();
    } catch (e) {
      throw new Error(message(e), { cause: e });
    }
    publish(source, await fetchLabels(source));
  }, [source]);

  const isLocal = source === LOCAL_TRIAGE_LABELS;

  const create = useCallback((draft) => (isLocal
    ? saveLocal([...(labels || []), {
      slug: slugifyTriageLabel(draft.name), color: null, ...draft, builtin: false, enabled: true,
    }])
    : writeApi(() => api.createTriageLabel(source, draft))), [isLocal, labels, saveLocal, writeApi, source]);

  const update = useCallback((label, patch) => (isLocal
    ? saveLocal((labels || []).map((l) => (l.slug === label.slug ? { ...l, ...patch } : l)))
    : writeApi(() => api.updateTriageLabel(source, label.id, patch))), [isLocal, labels, saveLocal, writeApi, source]);

  const remove = useCallback((label) => (isLocal
    ? saveLocal((labels || []).filter((l) => l.slug !== label.slug))
    : writeApi(() => api.deleteTriageLabel(source, label.id))), [isLocal, labels, saveLocal, writeApi, source]);

  return { labels, create, update, remove };
}
