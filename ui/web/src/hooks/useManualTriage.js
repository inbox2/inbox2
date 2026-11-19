import { useState, useEffect, useCallback } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import { getDb } from '../lib/db';
import syncManager from '../lib/sync-manager';
import log from '../lib/log';
import useUndoStore from '../stores/undoStore';
import useTriageLabels, { LOCAL_TRIAGE_LABELS } from './useTriageLabels';
import { CONVERSATION_PATCHED, HOLDING_PEN_SPACE, retriageConversation, setConversationSpace, setConversationLabel } from '../lib/triage';

/*
 * Manual triage for ONE conversation (the Triage menu's "Move to Space ›",
 * "Label ›" and "Re-run Jev"; docs/Triage.md "Manual triage").
 *
 *   useManualTriage(target) → { spaces, labels, currentSpace, currentLabel,
 *                               moveToSpace, setLabel, rerun } | null
 *
 * `target` = manualTriageTarget(conv, orgId) (or null → nothing loads):
 *   - local channel (Tauri): the engine's effective Spaces + the holding pen,
 *     its label list, and the row's current Space/label read from SQLite
 *     (refreshed on space-updated / triage-updated). Writes go through Tauri;
 *     the engine's events patch the rows.
 *   - MX: the org's Spaces (holding pen included) and labels over the API; the
 *     current values come from the row. After a write the updated conversation
 *     is broadcast as a CONVERSATION_PATCHED DOM event ({ id, patch }) so every
 *     list/detail holding that row can patch it in place.
 */

/**
 * Normalize any row shape (inbox list, unified column, search hit) into the
 * hook's target. Local-vs-MX: rows that carry a providerType say so; otherwise
 * local rows have `key` and MX rows only `id` (the reader's rule).
 */
export function manualTriageTarget(conv, orgId) {
  if (!conv?.id) return null;
  const local = conv.providerType ? conv.providerType !== 'inbox2' : !!conv.key;
  return {
    id: local ? (conv.key || conv.id) : conv.id,
    local,
    // Unified columns carry orgKey; search hits key MX rows by their org.
    orgId: local ? null : (conv.orgKey || (conv.providerType === 'inbox2' ? conv.accountKey : null) || orgId),
    label: conv.triage_label ?? null,
    space: conv.space?.slug ?? null,
  };
}

const mxSpaces = new Map(); // orgId → Promise<[{slug, name, key}]>, per session
function loadMxSpaces(orgId) {
  if (!mxSpaces.has(orgId)) {
    mxSpaces.set(orgId, api.getSpaces(orgId)
      .then((d) => (d.spaces || []).map((s) => ({ slug: s.slug, name: s.name, key: s.id })))
      .catch((e) => {
        log.warn('ManualTriage', `spaces ${orgId}: ${e?.message || e}`);
        mxSpaces.delete(orgId);
        return [];
      }));
  }
  return mxSpaces.get(orgId);
}

async function loadLocalSpaces() {
  const { invoke } = await import('@tauri-apps/api/core');
  const list = (await invoke('get_effective_spaces')) || [];
  return [...list.map((s) => ({ slug: s.slug, name: s.name || s.slug })), { slug: HOLDING_PEN_SPACE, name: 'Triage' }];
}

async function loadLocalCurrent(key) {
  const db = await getDb();
  const rows = db ? await db.select('SELECT space_slug, triage_label FROM conversations WHERE key = ?1', [key]) : [];
  return { space: rows[0]?.space_slug ?? null, label: rows[0]?.triage_label ?? null };
}

const fail = (what, e) => {
  log.warn('ManualTriage', `${what}: ${e?.message || e}`);
  useUndoStore.getState().notify({
    description: `${what}: ${e?.message || e}`,
    variant: 'danger',
    icon: 'exclamationmark.triangle',
  });
};

const patchMx = (id, conversation) => {
  if (conversation) document.dispatchEvent(new CustomEvent(CONVERSATION_PATCHED, { detail: { id, patch: conversation } }));
};

export default function useManualTriage(target) {
  const id = target?.id || null;
  const local = !!target?.local;
  const orgId = !local && isRealOrgId(target?.orgId) ? target.orgId : null;
  const enabled = !!id && (local || !!orgId);

  const { labels } = useTriageLabels(!enabled ? null : local ? LOCAL_TRIAGE_LABELS : orgId);
  const [spaces, setSpaces] = useState({ source: null, list: null });
  // Values we know better than the row: read from SQLite (local) or written by
  // this hook (MX, until the row itself is patched). Keyed by id.
  const [known, setKnown] = useState({ id: null });

  const source = !enabled ? null : local ? LOCAL_TRIAGE_LABELS : orgId;
  useEffect(() => {
    if (!source) return undefined;
    let live = true;
    (source === LOCAL_TRIAGE_LABELS ? loadLocalSpaces() : loadMxSpaces(source))
      .then((list) => { if (live) setSpaces({ source, list }); })
      .catch((e) => log.warn('ManualTriage', `spaces: ${e?.message || e}`));
    return () => { live = false; };
  }, [source]);

  useEffect(() => {
    if (!enabled || !local) return undefined;
    let live = true;
    const refresh = () => loadLocalCurrent(id)
      .then((cur) => { if (live) setKnown({ id, ...cur }); })
      .catch((e) => log.warn('ManualTriage', `current ${id}: ${e?.message || e}`));
    refresh();
    const onEvent = (p) => { if (p?.conversationKey === id) refresh(); };
    const offs = ['space-updated', 'triage-updated'].map((ev) => syncManager.on(ev, onEvent));
    return () => { live = false; offs.forEach((off) => off()); };
  }, [enabled, local, id]);

  const spaceList = spaces.source === source ? spaces.list : null;

  const moveToSpace = useCallback(async (slug) => {
    try {
      if (local) {
        await setConversationSpace(id, slug);
      } else {
        const space = spaceList?.find((s) => s.slug === slug);
        if (!space) throw new Error('unknown Space');
        patchMx(id, (await api.updateConversationSpace(orgId, id, space.key)).conversation);
      }
      setKnown((k) => ({ ...(k.id === id ? k : { id }), space: slug }));
    } catch (e) { fail("Couldn't move to Space", e); }
  }, [local, id, orgId, spaceList]);

  const setLabel = useCallback(async (slug) => {
    try {
      if (local) await setConversationLabel(id, slug);
      else patchMx(id, (await api.setConversationTriageLabel(orgId, id, slug)).conversation);
      setKnown((k) => ({ ...(k.id === id ? k : { id }), label: slug }));
    } catch (e) { fail("Couldn't set the label", e); }
  }, [local, id, orgId]);

  // Jev answers asynchronously (MX: a queued job; local: one Jev call); the
  // result arrives through the usual row refresh / engine events.
  const rerun = useCallback(async () => {
    useUndoStore.getState().notify({ description: 'Asking Jev again…', icon: 'arrow.triangle.2.circlepath' });
    try {
      if (local) await retriageConversation(id);
      else await api.retriageConversation(orgId, id);
    } catch (e) { fail("Couldn't re-run Jev", e); }
  }, [local, id, orgId]);

  if (!enabled) return null;
  const mine = known.id === id ? known : {};
  return {
    spaces: spaceList,
    labels: labels ? labels.filter((l) => l.enabled !== false) : null,
    currentSpace: 'space' in mine ? mine.space : target.space,
    currentLabel: 'label' in mine ? mine.label : target.label,
    moveToSpace,
    setLabel,
    rerun,
  };
}
