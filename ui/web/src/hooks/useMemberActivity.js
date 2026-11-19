import { useState, useEffect } from 'react';
import api from '../lib/api';
import { isRealOrgId } from '../lib/org';
import log from '../lib/log';

/* Per-member action tallies + daily sparkline for the Team activity board.
 * Keyed by member id so a card can look up its own row. Returns {} until loaded /
 * when there's no real org. Numbers are zero until the action paths log
 * ActivityEvents with a membership (telemetry follow-up) — the board renders the
 * honest empty state in the meantime. */
export default function useMemberActivity(orgId) {
  const [byMember, setByMember] = useState({});
  const [loading, setLoading] = useState(isRealOrgId(orgId));

  useEffect(() => {
    if (!isRealOrgId(orgId)) return undefined;
    let cancelled = false;
    (async () => {
      try {
        const d = await api.getMemberActivity(orgId);
        if (cancelled) return;
        const map = {};
        for (const row of d.activity || []) map[row.id] = row;
        setByMember(map);
      } catch (e) {
        log.warn('useMemberActivity', `failed: ${e?.message || e}`);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [orgId]);

  return { byMember, loading };
}
