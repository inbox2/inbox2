import { useEffect } from 'react';
import api from '../lib/localFirstApi';
import { isTauri } from '../lib/tauri';
import syncManager from '../lib/sync-manager';
import { loadAndEnrichExternalDetail } from '../lib/conversationDetail.js';
import { CONVERSATION_PATCHED } from '../lib/triage';

// Load the open conversation's detail when the selection changes: clears on
// deselect, loads external (Gmail/Microsoft) accounts from SQLite + provider
// enrich, and org/MX accounts from the API. `conversations` is the current list
// used to resolve the conversation's provider + account. Shared by the unified
// inbox and search-results views (their detail effects were identical).
export default function useSelectedConversationDetail({
  selectedId,
  conversations,
  setSelectedConv,
  setEnrichingKeys,
  logTag = 'ConvDetail',
}) {
  // Resolve the selected row's metadata (provider/account) from the list. On a
  // refresh-restore the selection can be set before the list has loaded, so meta
  // is momentarily missing — depend on it too, not just selectedId, so the detail
  // loads once the conversation appears (otherwise: row selected, empty preview).
  const meta = conversations.find(c => c.id === selectedId);
  useEffect(() => {
    if (!selectedId) { setSelectedConv(null); return; }
    if (!meta) { setSelectedConv(null); return; }

    let cancelled = false;
    if (meta.providerType !== 'inbox2') {
      if (!isTauri()) return;
      loadAndEnrichExternalDetail(meta.accountKey, selectedId, {
        onUpdate: setSelectedConv,
        onEnriching: setEnrichingKeys,
        isStale: () => cancelled,
        logTag,
        providerType: meta.providerType,
      });
    } else {
      // orgKey when the row came from a domain-keyed unified column (accountKey
      // is a dom_ id there); accountKey elsewhere (search rows key by org).
      api.getConversation(meta.orgKey || meta.accountKey, selectedId)
        .then(data => { if (!cancelled) setSelectedConv(data.conversation); })
        .catch(() => {});
    }
    return () => { cancelled = true; };
  // eslint-disable-next-line react-hooks/exhaustive-deps -- re-run when the selection OR its resolved row changes
  }, [selectedId, meta?.id, meta?.accountKey, meta?.orgKey, meta?.providerType]);

  // Live triage label updates (worker drain or the dev-mode re-classify): patch
  // the open detail's label in place — the engine already wrote SQLite.
  useEffect(() => {
    const off = syncManager.on('triage-updated', (payload) => {
      const key = payload?.conversationKey;
      if (!key) return;
      setSelectedConv(prev =>
        prev && (prev.key === key || prev.id === key) ? { ...prev, triage_label: payload.label, triage_priority: payload.priority ?? null } : prev);
    });
    // Manual triage on an MX thread (useManualTriage) patches it in place too.
    const onPatched = (e) => {
      const { id, patch } = e.detail || {};
      if (!id || !patch) return;
      setSelectedConv(prev => (prev?.id === id
        ? { ...prev, triage_label: patch.triage_label, triage_priority: patch.triage_priority, space: patch.space }
        : prev));
    };
    document.addEventListener(CONVERSATION_PATCHED, onPatched);
    return () => { off(); document.removeEventListener(CONVERSATION_PATCHED, onPatched); };
  // eslint-disable-next-line react-hooks/exhaustive-deps -- subscribe once; the setter is stable
  }, []);
}
