import { useCallback, useEffect, useState } from 'react';
import api from '../lib/api';
import log from '../lib/log';
import { isRealOrgId } from '../lib/org';
import { isTauri } from '../lib/tauri';
import useAuth from './useAuth';
import { isDemoMode, scrubIfDemo } from '../lib/demoData';

/*
 * What the ontology miner learned about one organization or person
 * (docs/Ontology.md): its facts with the quote each came from. Looks the entity
 * up in every MX org (API) and on this device (Tauri) by exact domain/address —
 * no review queue, everything mined is shown as is. One entry per store it was
 * found in, so an edit lands in the right one.
 *
 *   useLoreFacts({ kind: 'organization' | 'person', domain, address })
 *     → { hits: [{ store, entity, facts }], loading, refresh }
 *       store: { orgId } (MX) or { device: true }; hand edits go through loreEdits(store)
 */
const exact = (kind, domain, address) => (e) => (kind === 'organization'
  ? e.kind === kind && e.email_domain === domain
  : e.kind === kind && e.address === address);

async function fromOrg(orgId, kind, q, match) {
  const { entities } = await api.getLoreEntities(orgId, { kind, q });
  const hit = (entities || []).find(match);
  if (!hit) return [];
  const facts = (await api.getLoreEntity(orgId, hit.id)).entity?.facts || [];
  return [{ store: { orgId }, entity: hit, facts }];
}

async function fromDevice(kind, q, match) {
  const { invoke } = await import('@tauri-apps/api/core');
  // Engine reads bypass lib/db's demo scrub: scrub them here (lib/demoData.js).
  const { entities } = scrubIfDemo(await invoke('lore_entities', { kind, q }));
  const hit = (entities || []).find(match);
  if (!hit) return [];
  const facts = scrubIfDemo(await invoke('lore_entity', { id: hit.id })).entity?.facts || [];
  return [{ store: { device: true }, entity: hit, facts }];
}

/** Hand edits (docs/Ontology.md "Editing") against one store: MX over the API, the device over Tauri. */
export function loreEdits(store) {
  const mx = store.orgId;
  const tauri = async (cmd, args) => (await import('@tauri-apps/api/core')).invoke(cmd, args);
  return {
    rename: (id, name) => (mx ? api.updateLoreEntity(mx, id, { name }) : tauri('lore_entity_rename', { id, name })),
    setKind: (id, kind) => (mx ? api.updateLoreEntity(mx, id, { kind }) : tauri('lore_entity_set_kind', { id, kind })),
    merge: (id, into) => (mx ? api.mergeLoreEntity(mx, id, into) : tauri('lore_entity_merge', { id, into })),
    remove: (id) => (mx ? api.deleteLoreEntity(mx, id) : tauri('lore_entity_remove', { id })),
    search: async (q) => ((mx ? await api.getLoreEntities(mx, { q }) : await tauri('lore_entities', { q })).entities || []),
    editFact: (id, factId, body) => (mx ? api.updateLoreFact(mx, id, factId, body) : tauri('lore_fact_edit', { factId, ...body })),
    removeFact: (id, factId) => (mx ? api.deleteLoreFact(mx, id, factId) : tauri('lore_fact_remove', { factId })),
  };
}

// Stand-in facts for demo mode; the page's own name is the subject of them.
function demoFacts(kind) {
  const q = (text) => ({ quote: text, confidence: 0.8 });
  return kind === 'organization'
    ? [
      { kind: 'attribute', name: 'relationship', value: 'Customer since 2024', ...q('Thanks for another year with us — renewal confirmed for the 2025 term.') },
      { kind: 'attribute', name: 'project', value: 'Platform migration', ...q('The platform migration is on track for the end of the quarter.') },
      { kind: 'attribute', name: 'billing', value: 'Invoices monthly, 14-day terms', ...q('Payment is due within 14 days of the invoice date.') },
    ]
    : [
      { kind: 'attribute', name: 'role', value: 'Head of Operations', ...q('Looping in our Head of Operations, who owns the rollout on our side.') },
      { kind: 'attribute', name: 'prefers', value: 'A call over long threads', ...q('Happy to jump on a quick call instead if that is easier.') },
    ];
}

export default function useLoreFacts({ kind, domain, address }) {
  const { organizations } = useAuth();
  const [state, setState] = useState({ key: null, hits: [] });
  const [version, setVersion] = useState(0);
  const q = kind === 'organization' ? domain : address;
  const orgSig = (organizations || []).map((o) => o.id).filter(isRealOrgId).join(',');
  const key = `${kind}|${q}|${orgSig}`;

  useEffect(() => {
    if (!q) return undefined;
    // Demo mode: the page's names are stand-ins the miner never saw — show the
    // shape of what it learns, not real facts (lib/demoData.js).
    if (isDemoMode()) return undefined;
    let live = true;
    const match = exact(kind, domain, address);
    const soft = (p, where) => p.catch((e) => { log.warn('LoreFacts', `${where}: ${e?.message || e}`); return []; });
    Promise.all([
      ...(orgSig ? orgSig.split(',') : []).map((id) => soft(fromOrg(id, kind, q, match), id)),
      isTauri() ? soft(fromDevice(kind, q, match), 'device') : [],
    ]).then((parts) => {
      if (live) setState({ key, hits: parts.flat() });
    });
    return () => { live = false; };
  }, [key, kind, q, domain, address, orgSig, version]);

  const refresh = useCallback(() => setVersion((v) => v + 1), []);
  if (isDemoMode()) return { hits: [{ store: null, entity: null, facts: demoFacts(kind) }], loading: false, refresh };
  return { hits: state.key === key ? state.hits : [], loading: !!q && state.key !== key, refresh };
}
