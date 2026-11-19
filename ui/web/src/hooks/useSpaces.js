import { useState, useEffect, useCallback } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import { isTauri } from '../lib/tauri';
import { isDemoMode } from '../lib/demoData';
import log from '../lib/log';
import { MOCK_SPACES } from '../pages/dashboard/mockData';

/* Org-defined Spaces (MX classification buckets) for the treemap dashboard.
 *
 * Normalizes the API row to the shape the treemap/components expect:
 *   - `id`  = slug, so the canonical color system (lib/spaceColors) and the
 *             per-space message strips (SPACE_MESSAGES) stay keyed the same way
 *             across clients.
 *   - `key` = the spc_… public id, kept for future create/update/delete calls.
 *
 * MOCK_SPACES is used ONLY for the unguarded /spaces design preview (no real
 * org). A real org shows its own spaces — and nothing (not the sample data)
 * while loading or on error — so the hardcoded prototype never flashes in
 * production. `isMock` is true exactly for that no-real-org preview. */
function normalize(s) {
  return {
    id: s.slug || s.id,
    key: s.id,
    name: s.name,
    slug: s.slug,
    icon: s.icon,
    color: s.color,
    description: s.description,
    not_for: s.not_for,
    classify: s.classify,
    openness: s.openness,
    open: s.open ?? 0,
    unread: s.unread ?? 0,
    volume: s.volume ?? 0,
    unassigned: s.unassigned ?? 0,
    members: (s.members || []).map((m) => ({ key: m.key, name: m.name, avatar_url: m.avatar_url || null })),
  };
}

export default function useSpaces(orgId) {
  const isRealOrg = isRealOrgId(orgId);
  const [spaces, setSpaces] = useState(null);
  const [loading, setLoading] = useState(isRealOrg);
  const [nonce, setNonce] = useState(0);

  // Manual refresh hook for after create/update/delete (bumps the effect).
  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    if (!isRealOrg) return undefined;
    let cancelled = false;
    (async () => {
      try {
        const data = await api.getSpaces(orgId);
        const list = (data.spaces || []).map(normalize);
        if (!cancelled) setSpaces(list);
        // Desktop: keep the local-channel Space sorting (Jev) in sync with the
        // org's real classifiable spaces whenever they load — the same
        // name/description/not_for the MX triage asks with. Fire-and-forget.
        // Never in demo mode: the read is scrubbed (fake descriptions), and
        // pushing it would re-file every thread against made-up Spaces.
        if (isTauri() && !isDemoMode()) {
          const taxonomy = list
            .filter((s) => s.slug && s.classify !== false)
            .map((s) => ({ slug: s.slug, name: s.name, description: s.description || '', not_for: s.not_for || '' }));
          if (taxonomy.length) {
            import('@tauri-apps/api/core')
              .then(({ invoke }) => invoke('set_space_taxonomy', { spacesJson: JSON.stringify(taxonomy) }))
              .catch((e) => log.warn('useSpaces', `taxonomy push failed: ${e?.message || e}`));
          }
        }
      } catch (e) {
        // Real org: an error shows an empty board, never the mock sample.
        log.warn('useSpaces', `Failed to load spaces: ${e?.message || e}`);
        if (!cancelled) setSpaces([]);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [orgId, isRealOrg, nonce]);

  // Mock only for the no-real-org design preview. A real org resolves to its
  // own spaces (or [] while loading) so the hardcoded data never appears.
  return {
    spaces: isRealOrg ? (spaces ?? []) : MOCK_SPACES,
    isMock: !isRealOrg,
    loading,
    reload,
  };
}
